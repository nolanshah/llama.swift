//
//  LlamaPredictOperation.m
//  llama
//
//  Created by Alex Rozanski on 13/03/2023.
//

#import "LlamaPredictOperation.hh"

#import "LlamaError.h"
#import "LlamaEvent.h"
#import "LlamaRunnerBridgeConfig.h"

#include "ggml.h"

#include "utils.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#if defined (__unix__) || (defined (__APPLE__) && defined (__MACH__))
#include <signal.h>
#include <unistd.h>
#endif

// determine number of model parts based on the dimension
static const std::map<int, int> LLAMA_N_PARTS = {
  { 4096, 1 },
  { 5120, 2 },
  { 6656, 4 },
  { 8192, 8 },
};

// default hparams (LLaMA 7B)
struct llama_hparams {
  int32_t n_vocab = 32000;
  int32_t n_ctx   = 512;   // this is provided as user input?
  int32_t n_embd  = 4096;
  int32_t n_mult  = 256;
  int32_t n_head  = 32;
  int32_t n_layer = 32;
  int32_t n_rot   = 64;
  int32_t f16     = 1;
};

struct llama_layer {
  // normalization
  struct ggml_tensor * attention_norm;

  // attention
  struct ggml_tensor * wq;
  struct ggml_tensor * wk;
  struct ggml_tensor * wv;
  struct ggml_tensor * wo;

  // normalization
  struct ggml_tensor * ffn_norm;

  // ff
  struct ggml_tensor * w1;
  struct ggml_tensor * w2;
  struct ggml_tensor * w3;
};

struct llama_model {
  llama_hparams hparams;

  struct ggml_tensor * tok_embeddings;

  struct ggml_tensor * norm;
  struct ggml_tensor * output;

  std::vector<llama_layer> layers;

  // key + value memory
  struct ggml_tensor * memory_k;
  struct ggml_tensor * memory_v;

  //
  struct ggml_context * ctx;
  std::map<std::string, struct ggml_tensor *> tensors;
};

NSError *makeLlamaError(LlamaErrorCode errorCode, NSString *description)
{
  return [[NSError alloc] initWithDomain:LlamaErrorDomain code:errorCode userInfo:@{
    NSLocalizedDescriptionKey: description
  }];
}

// load the model's weights from a file
bool llama_model_load(const std::string & fname, llama_model & model, gpt_vocab & vocab, int n_ctx, NSError **outError) {
  auto fin = std::ifstream(fname, std::ios::binary);
  if (!fin) {
    *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                               [NSString stringWithFormat:@"failed to open '%s'", fname.c_str()]);
    return false;
  }

  // verify magic
  // {
  //   uint32_t magic;
  //   fin.read((char *) &magic, sizeof(magic));
  //   if (magic != 0x67676d6c) {
  //     *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
  //                                [NSString stringWithFormat:@"invalid model file '%s' (bad magic)", fname.c_str()]);
  //     return false;
  //   }
  // }

  int n_ff = 0;
  int n_parts = 0;

  // load hparams
  {
    auto & hparams = model.hparams;

    fin.read((char *) &hparams.n_vocab, sizeof(hparams.n_vocab));
    //fin.read((char *) &hparams.n_ctx,   sizeof(hparams.n_ctx));
    fin.read((char *) &hparams.n_embd,  sizeof(hparams.n_embd));
    fin.read((char *) &hparams.n_mult,  sizeof(hparams.n_mult));
    fin.read((char *) &hparams.n_head,  sizeof(hparams.n_head));
    fin.read((char *) &hparams.n_layer, sizeof(hparams.n_layer));
    fin.read((char *) &hparams.n_rot,   sizeof(hparams.n_rot));
    fin.read((char *) &hparams.f16,     sizeof(hparams.f16));

    hparams.n_ctx = n_ctx;

    n_ff = ((2*(4*hparams.n_embd)/3 + hparams.n_mult - 1)/hparams.n_mult)*hparams.n_mult;
    n_parts = LLAMA_N_PARTS.at(hparams.n_embd);
  }

  // load vocab
  {
    const int32_t n_vocab = model.hparams.n_vocab;

    if (n_vocab != model.hparams.n_vocab) {
      *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                 [NSString stringWithFormat:@"invalid model file '%s' (bad vocab size %d != %d)", fname.c_str(), n_vocab, model.hparams.n_vocab]);
      return false;
    }

    std::string word;
    for (int i = 0; i < n_vocab; i++) {
      uint32_t len;
      fin.read((char *) &len, sizeof(len));

      word.resize(len);
      fin.read((char *) word.data(), len);

      vocab.token_to_id[word] = i;
      vocab.id_to_token[i] = word;

      //if (i < 30000) {
      //    printf("%s: vocab[%d] = '%s'\n", __func__, i, word.c_str());
      //}
    }
  }

  // for the big tensors, we have the option to store the data in 16-bit floats or quantized
  // in order to save memory and also to speed up the computation
  ggml_type wtype = GGML_TYPE_COUNT;
  switch (model.hparams.f16) {
    case 0: wtype = GGML_TYPE_F32;  break;
    case 1: wtype = GGML_TYPE_F16;  break;
    case 2: wtype = GGML_TYPE_Q4_0; break;
    case 3: wtype = GGML_TYPE_Q4_1; break;
    default:
    {
      *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                 [NSString stringWithFormat:@"invalid model file '%s' (bad f16 value %d)", fname.c_str(), model.hparams.f16]);
      return false;
    }
  }

  const ggml_type wtype2 = GGML_TYPE_F32;

  auto & ctx = model.ctx;

  size_t ctx_size = 0;

  {
    const auto & hparams = model.hparams;

    const int n_embd  = hparams.n_embd;
    const int n_layer = hparams.n_layer;
    const int n_ctx   = hparams.n_ctx;
    const int n_vocab = hparams.n_vocab;

    ctx_size += n_embd*n_vocab*ggml_type_sizef(wtype); // tok_embeddings

    ctx_size += n_embd*ggml_type_sizef(GGML_TYPE_F32); // norm

    ctx_size += n_embd*n_vocab*ggml_type_sizef(wtype); // output

    ctx_size += n_layer*(n_embd*ggml_type_sizef(GGML_TYPE_F32)); // attention_norm

    ctx_size += n_layer*(n_embd*n_embd*ggml_type_sizef(wtype)); // wq
    ctx_size += n_layer*(n_embd*n_embd*ggml_type_sizef(wtype)); // wk
    ctx_size += n_layer*(n_embd*n_embd*ggml_type_sizef(wtype)); // wv
    ctx_size += n_layer*(n_embd*n_embd*ggml_type_sizef(wtype)); // wo

    ctx_size += n_layer*(n_embd*ggml_type_sizef(GGML_TYPE_F32)); // ffn_norm

    ctx_size += n_layer*(n_ff*n_embd*ggml_type_sizef(wtype)); // w1
    ctx_size += n_layer*(n_ff*n_embd*ggml_type_sizef(wtype)); // w2
    ctx_size += n_layer*(n_ff*n_embd*ggml_type_sizef(wtype)); // w3

    ctx_size += n_ctx*n_layer*n_embd*ggml_type_sizef(GGML_TYPE_F32); // memory_k
    ctx_size += n_ctx*n_layer*n_embd*ggml_type_sizef(GGML_TYPE_F32); // memory_v

    ctx_size += (5 + 10*n_layer)*256; // object overhead
  }

  // create the ggml context
  {
    struct ggml_init_params params = {
      /*.mem_size   =*/ ctx_size,
      /*.mem_buffer =*/ NULL,
    };

    model.ctx = ggml_init(params);
    if (!model.ctx) {
      *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel, [NSString stringWithFormat:@"ggml_init() failed"]);
      return false;
    }
  }

  // prepare memory for the weights
  {
    const auto & hparams = model.hparams;

    const int n_embd  = hparams.n_embd;
    const int n_layer = hparams.n_layer;
    const int n_ctx   = hparams.n_ctx;
    const int n_vocab = hparams.n_vocab;

    model.layers.resize(n_layer);

    model.tok_embeddings = ggml_new_tensor_2d(ctx, wtype, n_embd, n_vocab);

    model.norm   = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_embd);
    model.output = ggml_new_tensor_2d(ctx, wtype,         n_embd, n_vocab);

    // map by name
    model.tensors["tok_embeddings.weight"] = model.tok_embeddings;

    model.tensors["norm.weight"]   = model.norm;
    model.tensors["output.weight"] = model.output;

    for (int i = 0; i < n_layer; ++i) {
      auto & layer = model.layers[i];

      layer.attention_norm = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_embd);

      layer.wq = ggml_new_tensor_2d(ctx, wtype, n_embd, n_embd);
      layer.wk = ggml_new_tensor_2d(ctx, wtype, n_embd, n_embd);
      layer.wv = ggml_new_tensor_2d(ctx, wtype, n_embd, n_embd);
      layer.wo = ggml_new_tensor_2d(ctx, wtype, n_embd, n_embd);

      layer.ffn_norm = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_embd);

      layer.w1 = ggml_new_tensor_2d(ctx, wtype, n_embd,   n_ff);
      layer.w2 = ggml_new_tensor_2d(ctx, wtype,   n_ff, n_embd);
      layer.w3 = ggml_new_tensor_2d(ctx, wtype, n_embd,   n_ff);

      // map by name
      model.tensors["layers." + std::to_string(i) + ".attention_norm.weight"] = layer.attention_norm;

      model.tensors["layers." + std::to_string(i) + ".attention.wq.weight"] = layer.wq;
      model.tensors["layers." + std::to_string(i) + ".attention.wk.weight"] = layer.wk;
      model.tensors["layers." + std::to_string(i) + ".attention.wv.weight"] = layer.wv;
      model.tensors["layers." + std::to_string(i) + ".attention.wo.weight"] = layer.wo;

      model.tensors["layers." + std::to_string(i) + ".ffn_norm.weight"] = layer.ffn_norm;

      model.tensors["layers." + std::to_string(i) + ".feed_forward.w1.weight"] = layer.w1;
      model.tensors["layers." + std::to_string(i) + ".feed_forward.w2.weight"] = layer.w2;
      model.tensors["layers." + std::to_string(i) + ".feed_forward.w3.weight"] = layer.w3;
    }
  }

  // key + value memory
  {
    const auto & hparams = model.hparams;

    const int n_embd  = hparams.n_embd;
    const int n_layer = hparams.n_layer;
    const int n_ctx   = hparams.n_ctx;

    const int n_mem      = n_layer*n_ctx;
    const int n_elements = n_embd*n_mem;

    model.memory_k = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_elements);
    model.memory_v = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, n_elements);

    const size_t memory_size = ggml_nbytes(model.memory_k) + ggml_nbytes(model.memory_v);
  }

  const size_t file_offset = fin.tellg();

  fin.close();

  std::vector<uint8_t> tmp;

  for (int i = 0; i < n_parts; ++i) {
    const int part_id = i;
    //const int part_id = n_parts - i - 1;

    std::string fname_part = fname;
    if (i > 0) {
      fname_part += "." + std::to_string(i);
    }

    fin = std::ifstream(fname_part, std::ios::binary);
    fin.seekg(file_offset);

    // load weights
    {
      int n_tensors = 0;
      size_t total_size = 0;

      while (true) {
        int32_t n_dims;
        int32_t length;
        int32_t ftype;

        fin.read(reinterpret_cast<char *>(&n_dims), sizeof(n_dims));
        fin.read(reinterpret_cast<char *>(&length), sizeof(length));
        fin.read(reinterpret_cast<char *>(&ftype),  sizeof(ftype));

        if (fin.eof()) {
          break;
        }

        int32_t nelements = 1;
        int32_t ne[2] = { 1, 1 };
        for (int i = 0; i < n_dims; ++i) {
          fin.read(reinterpret_cast<char *>(&ne[i]), sizeof(ne[i]));
          nelements *= ne[i];
        }

        std::string name(length, 0);
        fin.read(&name[0], length);

        if (model.tensors.find(name.data()) == model.tensors.end()) {
          *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                     [NSString stringWithFormat:@"unknown tensor '%s' in model file", name.data()]);
          return false;
        }

        // split_type = 0: split by columns
        // split_type = 1: split by rows
        int split_type = 0;

        // split_type = 0:
        // regex:
        //   - tok_embeddings.*
        //   - layers.*.attention.wo.weight
        //   - layers.*.feed_forward.w2.weight

        // split_type = 1:
        // regex:
        //   - output.*
        //   - layers.*.attention.wq.weight
        //   - layers.*.attention.wk.weight
        //   - layers.*.attention.wv.weight
        //   - layers.*.feed_forward.w1.weight
        //   - layers.*.feed_forward.w3.weight
        if (name.find("tok_embeddings") != std::string::npos) {
          split_type = 0;
        } else if (name.find("layers") != std::string::npos) {
          if (name.find("attention.wo.weight") != std::string::npos) {
            split_type = 0;
          } else if (name.find("feed_forward.w2.weight") != std::string::npos) {
            split_type = 0;
          } else {
            split_type = 1;
          }
        } else if (name.find("output") != std::string::npos) {
          split_type = 1;
        }

        auto tensor = model.tensors[name.data()];

        if (n_dims == 1) {
          if (ggml_nelements(tensor) != nelements) {
            *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                       [NSString stringWithFormat:@"tensor '%s' has wrong size in model file", name.data()]);
            return false;
          }
        } else {
          if (ggml_nelements(tensor)/n_parts != nelements) {
            *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                       [NSString stringWithFormat:@"tensor '%s' has wrong size in model file", name.data()]);
            return false;
          }
        }

        if (n_dims == 1) {
          if (tensor->ne[0] != ne[0] || tensor->ne[1] != ne[1]) {
            *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                       [NSString stringWithFormat:@"tensor '%s' has wrong shape in model file: got [%d, %d], expected [%d, %d]", name.data(), tensor->ne[0], tensor->ne[1], ne[0], ne[1]]);
            return false;
          }
        } else {
          if (split_type == 0) {
            if (tensor->ne[0]/n_parts != ne[0] || tensor->ne[1] != ne[1]) {
              *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                         [NSString stringWithFormat:@"tensor '%s' has wrong shape in model file: got [%d, %d], expected [%d, %d]", name.data(), tensor->ne[0]/n_parts, tensor->ne[1], ne[0], ne[1]]);
              return false;
            }
          } else {
            if (tensor->ne[0] != ne[0] || tensor->ne[1]/n_parts != ne[1]) {
              *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                         [NSString stringWithFormat:@"tensor '%s' has wrong shape in model file: got [%d, %d], expected [%d, %d]", name.data(), tensor->ne[0], tensor->ne[1]/n_parts, ne[0], ne[1]]);
              return false;
            }
          }
        }

        if (0) {
          static const char * ftype_str[] = { "f32", "f16", "q4_0", "q4_1", };
        }

        size_t bpe = 0;

        switch (ftype) {
          case 0: bpe = ggml_type_size(GGML_TYPE_F32);  break;
          case 1: bpe = ggml_type_size(GGML_TYPE_F16);  break;
          case 2: bpe = ggml_type_size(GGML_TYPE_Q4_0); assert(ne[0] % 64 == 0); break;
          case 3: bpe = ggml_type_size(GGML_TYPE_Q4_1); assert(ne[0] % 64 == 0); break;
          default:
          {
            *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel, [NSString stringWithFormat:@"unknown ftype %d in model file", ftype]);
            return false;
          }
        };

        if (n_dims == 1 || n_parts == 1) {
          if ((nelements*bpe)/ggml_blck_size(tensor->type) != ggml_nbytes(tensor)) {
            *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                       [NSString stringWithFormat:@"tensor '%s' has wrong size in model file: got %zu, expected %zu", name.data(), ggml_nbytes(tensor), nelements*bpe]);
            return false;
          }

          if (part_id == 0) {
            fin.read(reinterpret_cast<char *>(tensor->data), ggml_nbytes(tensor));
          } else {
            fin.seekg(ggml_nbytes(tensor), std::ios::cur);
          }

          total_size += ggml_nbytes(tensor);
        } else {
          if ((nelements*bpe)/ggml_blck_size(tensor->type) != ggml_nbytes(tensor)/n_parts) {
            *outError = makeLlamaError(LlamaErrorCodeFailedToLoadModel,
                                       [NSString stringWithFormat:@"tensor '%s' has wrong size in model file: got %zu, expected %zu", name.data(), ggml_nbytes(tensor)/n_parts, nelements*bpe]);
            return false;
          }

          if (split_type == 0) {
            const int np0 = ne[0];

            const size_t row_size = (tensor->ne[0]/ggml_blck_size(tensor->type))*ggml_type_size(tensor->type);
            assert(row_size == tensor->nb[1]);

            for (int i1 = 0; i1 < ne[1]; ++i1) {
              const size_t offset_row = i1*row_size;
              const size_t offset = offset_row + ((part_id*np0)/ggml_blck_size(tensor->type))*ggml_type_size(tensor->type);
              fin.read(reinterpret_cast<char *>(tensor->data) + offset, row_size/n_parts);
            }
          } else {
            const int np1 = ne[1];

            const size_t row_size = (tensor->ne[0]/ggml_blck_size(tensor->type))*ggml_type_size(tensor->type);

            for (int i1 = 0; i1 < ne[1]; ++i1) {
              const size_t offset_row = (i1 + part_id*np1)*row_size;
              fin.read(reinterpret_cast<char *>(tensor->data) + offset_row, row_size);
            }
          }

          total_size += ggml_nbytes(tensor)/n_parts;
        }
      }
    }

    fin.close();
  }

  return true;
}

// evaluate the transformer
//
//   - model:     the model
//   - n_threads: number of threads to use
//   - n_past:    the context size so far
//   - embd_inp:  the embeddings of the tokens in the context
//   - embd_w:    the predicted logits for the next token
//
// The GPT-J model requires about 16MB of memory per input token.
//
bool llama_eval(
                const llama_model & model,
                const int n_threads,
                const int n_past,
                const std::vector<gpt_vocab::id> & embd_inp,
                std::vector<float>         & embd_w,
                size_t                     & mem_per_token,
                NSError **outError
) {
  const int N = embd_inp.size();

  const auto & hparams = model.hparams;

  const int n_embd  = hparams.n_embd;
  const int n_layer = hparams.n_layer;
  const int n_ctx   = hparams.n_ctx;
  const int n_head  = hparams.n_head;
  const int n_vocab = hparams.n_vocab;
  const int n_rot   = hparams.n_embd/hparams.n_head;

  const int d_key = n_embd/n_head;

  static size_t buf_size = 512u*1024*1024;
  static void * buf = malloc(buf_size);

  if (mem_per_token > 0 && mem_per_token*N > buf_size) {
    const size_t buf_size_new = 1.1*(mem_per_token*N); // add 10% to account for ggml object overhead
    //printf("\n%s: reallocating buffer from %zu to %zu bytes\n", __func__, buf_size, buf_size_new);

    // reallocate
    buf_size = buf_size_new;
    buf = realloc(buf, buf_size);
    if (buf == nullptr) {
      *outError = makeLlamaError(LlamaErrorCodePredictionFailed,
                                 [NSString stringWithFormat:@"failed to allocate %zu bytes", buf_size]);
      return false;
    }
  }

  struct ggml_init_params params = {
    /*.mem_size   =*/ buf_size,
    /*.mem_buffer =*/ buf,
  };

  struct ggml_context * ctx0 = ggml_init(params);
  ggml_cgraph gf = {};
  gf.n_threads = n_threads;

  struct ggml_tensor * embd = ggml_new_tensor_1d(ctx0, GGML_TYPE_I32, N);
  memcpy(embd->data, embd_inp.data(), N*ggml_element_size(embd));

  struct ggml_tensor * inpL = ggml_get_rows(ctx0, model.tok_embeddings, embd);

  for (int il = 0; il < n_layer; ++il) {
    struct ggml_tensor * inpSA = inpL;

    struct ggml_tensor * cur;

    // norm
    {
      cur = ggml_norm(ctx0, inpL);

      // cur = attention_norm*cur
      cur = ggml_mul(ctx0,
                     ggml_repeat(ctx0, model.layers[il].attention_norm, cur),
                     cur);
    }

    // self-attention
    {
      struct ggml_tensor * Qcur = ggml_mul_mat(ctx0, model.layers[il].wq, cur);
      struct ggml_tensor * Kcur = ggml_mul_mat(ctx0, model.layers[il].wk, cur);
      struct ggml_tensor * Vcur = ggml_mul_mat(ctx0, model.layers[il].wv, cur);

      // store key and value to memory
      if (N >= 1) {
        struct ggml_tensor * k = ggml_view_1d(ctx0, model.memory_k, N*n_embd, (ggml_element_size(model.memory_k)*n_embd)*(il*n_ctx + n_past));
        struct ggml_tensor * v = ggml_view_1d(ctx0, model.memory_v, N*n_embd, (ggml_element_size(model.memory_v)*n_embd)*(il*n_ctx + n_past));

        ggml_build_forward_expand(&gf, ggml_cpy(ctx0, Kcur, k));
        ggml_build_forward_expand(&gf, ggml_cpy(ctx0, Vcur, v));
      }

      // Q = Qcur.contiguous().view(n_embd/n_head, n_head, N).permute(0, 2, 1, 3)
      struct ggml_tensor * Q =
      ggml_permute(ctx0,
                   ggml_rope(ctx0,
                             ggml_cpy(ctx0,
                                      Qcur,
                                      ggml_new_tensor_3d(ctx0, GGML_TYPE_F32, n_embd/n_head, n_head, N)),
                             n_past, n_rot, 0),
                   0, 2, 1, 3);

      // K = Kmem.view(n_embd/n_head, n_head, n_past + N).permute(0, 2, 1, 3)
      struct ggml_tensor * K =
      ggml_permute(ctx0,
                   ggml_rope(ctx0,
                             ggml_reshape_3d(ctx0,
                                             ggml_view_1d(ctx0, model.memory_k, (n_past + N)*n_embd, il*n_ctx*ggml_element_size(model.memory_k)*n_embd),
                                             n_embd/n_head, n_head, n_past + N),
                             n_past, n_rot, 1),
                   0, 2, 1, 3);

      // K * Q
      struct ggml_tensor * KQ = ggml_mul_mat(ctx0, K, Q);

      // KQ_scaled = KQ / sqrt(n_embd/n_head)
      struct ggml_tensor * KQ_scaled =
      ggml_scale(ctx0,
                 KQ,
                 ggml_new_f32(ctx0, 1.0f/sqrt(float(n_embd)/n_head))
                 );

      // KQ_masked = mask_past(KQ_scaled)
      struct ggml_tensor * KQ_masked = ggml_diag_mask_inf(ctx0, KQ_scaled, n_past);

      // KQ = soft_max(KQ_masked)
      struct ggml_tensor * KQ_soft_max = ggml_soft_max(ctx0, KQ_masked);

      // V_trans = Vmem.view(n_embd/n_head, n_head, n_past + N).permute(1, 2, 0, 3).contiguous()
      struct ggml_tensor * V_trans =
      ggml_permute(ctx0,
                   ggml_reshape_3d(ctx0,
                                   ggml_view_1d(ctx0, model.memory_v, (n_past + N)*n_embd, il*n_ctx*ggml_element_size(model.memory_v)*n_embd),
                                   n_embd/n_head, n_head, n_past + N),
                   1, 2, 0, 3);

      // KQV = transpose(V) * KQ_soft_max
      struct ggml_tensor * KQV = ggml_mul_mat(ctx0, V_trans, KQ_soft_max);

      // KQV_merged = KQV.permute(0, 2, 1, 3)
      struct ggml_tensor * KQV_merged = ggml_permute(ctx0, KQV, 0, 2, 1, 3);

      // cur = KQV_merged.contiguous().view(n_embd, N)
      cur = ggml_cpy(ctx0,
                     KQV_merged,
                     ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, n_embd, N));

      // projection (no bias)
      cur = ggml_mul_mat(ctx0,
                         model.layers[il].wo,
                         cur);
    }

    struct ggml_tensor * inpFF = ggml_add(ctx0, cur, inpSA);

    // feed-forward network
    {
      // norm
      {
        cur = ggml_norm(ctx0, inpFF);

        // cur = ffn_norm*cur
        cur = ggml_mul(ctx0,
                       ggml_repeat(ctx0, model.layers[il].ffn_norm, cur),
                       cur);
      }

      struct ggml_tensor * tmp = ggml_mul_mat(ctx0,
                                              model.layers[il].w3,
                                              cur);


      cur = ggml_mul_mat(ctx0,
                         model.layers[il].w1,
                         cur);

      // SILU activation
      cur = ggml_silu(ctx0, cur);

      cur = ggml_mul(ctx0, cur, tmp);

      cur = ggml_mul_mat(ctx0,
                         model.layers[il].w2,
                         cur);
    }

    cur  = ggml_add(ctx0, cur, inpFF);

    // input for next layer
    inpL = cur;
  }

  // norm
  {
    inpL = ggml_norm(ctx0, inpL);

    // inpL = norm*inpL
    inpL = ggml_mul(ctx0,
                    ggml_repeat(ctx0, model.norm, inpL),
                    inpL);
  }

  // lm_head
  {
    inpL = ggml_mul_mat(ctx0, model.output, inpL);
  }

  // logits -> probs
  //inpL = ggml_soft_max(ctx0, inpL);

  // run the computation
  ggml_build_forward_expand(&gf, inpL);
  ggml_graph_compute       (ctx0, &gf);

  //if (n_past%100 == 0) {
  //    ggml_graph_print   (&gf);
  //    ggml_graph_dump_dot(&gf, NULL, "gpt-2.dot");
  //}

  //embd_w.resize(n_vocab*N);
  //memcpy(embd_w.data(), ggml_get_data(inpL), sizeof(float)*n_vocab*N);

  // return result for just the last token
  embd_w.resize(n_vocab);
  memcpy(embd_w.data(), (float *) ggml_get_data(inpL) + (n_vocab*(N-1)), sizeof(float)*n_vocab);

  if (mem_per_token == 0) {
    mem_per_token = ggml_used_mem(ctx0)/N;
  }
  //printf("used_mem = %zu\n", ggml_used_mem(ctx0));

  ggml_free(ctx0);

  return true;
}

#if defined (__unix__) || (defined (__APPLE__) && defined (__MACH__))
void sigint_handler(int signo) {
  if (signo == SIGINT) {
    _exit(130);
  }
}
#endif

@interface LlamaPredictOperation () {
  gpt_params _params;
  LlamaPredictOperationEventHandler _eventHandler;
  dispatch_queue_t _eventHandlerQueue;
}

@end

@implementation LlamaPredictOperation

- (instancetype)initWithParams:(gpt_params)params
                  eventHandler:(LlamaPredictOperationEventHandler)eventHandler
             eventHandlerQueue:(dispatch_queue_t)eventHandlerQueue
{
  if ((self = [super init])) {
    _params = params;
    _eventHandler = [eventHandler copy];
    _eventHandlerQueue = eventHandlerQueue;
  }

  return self;
}

- (void)main
{
  ggml_time_init();
  const int64_t t_main_start_us = ggml_time_us();

  std::mt19937 rng(_params.seed);
  if (_params.prompt.empty()) {
    _params.prompt = gpt_random_prompt(rng);
  }

  int64_t t_load_us = 0;

  gpt_vocab vocab;
  llama_model model;

  // load the model
  {
    [self postEvent:[_LlamaEvent startedLoadingModel]];

    const int64_t t_start_us = ggml_time_us();

    NSError *loadError = nil;
    if (!llama_model_load(_params.model, model, vocab, 512, &loadError)) {  // TODO: set context from user input ??
      [self postEvent:[_LlamaEvent failedWithError:loadError]];
      return;
    }

    t_load_us = ggml_time_us() - t_start_us;

    [self postEvent:[_LlamaEvent finishedLoadingModel]];
  }

  [self postEvent:[_LlamaEvent startedGeneratingOutput]];

  int n_past = 0;

  int64_t t_sample_us  = 0;
  int64_t t_predict_us = 0;

  std::vector<float> logits;

  // tokenize the prompt
  std::vector<gpt_vocab::id> embd_inp = ::llama_tokenize(vocab, _params.prompt, true);

  _params.n_predict = std::min(_params.n_predict, model.hparams.n_ctx - (int) embd_inp.size());

  // tokenize the reverse prompt
  std::vector<gpt_vocab::id> antiprompt_inp = ::llama_tokenize(vocab, _params.antiprompt, false);

  std::vector<gpt_vocab::id> embd;

  // determine the required inference memory per token:
  size_t mem_per_token = 0;
  NSError *error = nil;
  if (!llama_eval(model, _params.n_threads, 0, { 0, 1, 2, 3 }, logits, mem_per_token, &error)) {
    [self postEvent:[_LlamaEvent failedWithError:error]];
    return;
  }

  int last_n_size = _params.repeat_last_n;
  std::vector<gpt_vocab::id> last_n_tokens(last_n_size);
  std::fill(last_n_tokens.begin(), last_n_tokens.end(), 0);

  int remaining_tokens = _params.n_predict;
  int input_consumed = 0;

  while (remaining_tokens > 0) {
    // predict
    if (embd.size() > 0) {
      const int64_t t_start_us = ggml_time_us();

      NSError *error = nil;
      if (!llama_eval(model, _params.n_threads, n_past, embd, logits, mem_per_token, &error)) {
        [self postEvent:[_LlamaEvent failedWithError:error]];
        return;
      }

      t_predict_us += ggml_time_us() - t_start_us;
    }

    n_past += embd.size();
    embd.clear();

    if (embd_inp.size() <= input_consumed) {
      // out of user input, sample next token
      const float top_k = _params.top_k;
      const float top_p = _params.top_p;
      const float temp  = _params.temp;
      const float repeat_penalty = _params.repeat_penalty;

      const int n_vocab = model.hparams.n_vocab;

      gpt_vocab::id id = 0;

      {
        const int64_t t_start_sample_us = ggml_time_us();

        id = llama_sample_top_p_top_k(vocab, logits.data() + (logits.size() - n_vocab), last_n_tokens, repeat_penalty, top_k, top_p, temp, rng);

        last_n_tokens.erase(last_n_tokens.begin());
        last_n_tokens.push_back(id);

        t_sample_us += ggml_time_us() - t_start_sample_us;
      }

      // add it to the context
      embd.push_back(id);

      // decrement remaining sampling budget
      --remaining_tokens;
    } else {
      // some user input remains from prompt or interaction, forward it to processing
      while (embd_inp.size() > input_consumed) {
        embd.push_back(embd_inp[input_consumed]);
        last_n_tokens.erase(last_n_tokens.begin());
        last_n_tokens.push_back(embd_inp[input_consumed]);
        ++input_consumed;
        if (embd.size() > _params.n_batch) {
          break;
        }
      }
    }

    // display text
    for (auto id : embd) {
      NSString *token = [[NSString alloc] initWithCString:vocab.id_to_token[id].c_str() encoding:NSUTF8StringEncoding];
      [self postEvent:[_LlamaEvent outputTokenWithToken:token]];
    }
  }

  [self postEvent:[_LlamaEvent completed]];

  ggml_free(model.ctx);
}

- (void)postEvent:(_LlamaEvent *)event
{
  dispatch_async(_eventHandlerQueue, ^() {
    if (self->_eventHandler != NULL) {
      self->_eventHandler(event);
    }
  });
}

@end
