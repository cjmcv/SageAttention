/*
 * Copyright (c) 2024 by SageAttention team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "../utils.cuh"
#include <cuda.h>
#include <cuda_bf16.h>
#include <cuda_fp8.h>
#include <torch/extension.h>

#include "../wgmma.cuh"
#include "../math.cuh"
#include "../dispatch_utils.h"

#include "attn_utils.cuh"

// <NT> 创建一个 4 维张量映射，通过 cuTensorMapEncodeTiled 将全局内存中的张量映射到共享内存中的块。
// 用于高效地管理张量（多维数组）的内存访问，内存布局是 d1-d4 [batch_size, nhead, seq_len, head_dim]. gmem_prob_shapep[head_dim, seq_len, nhead, batch_size]
template <int BlockMajorSize, int BlockMinorSize, bool swizzle=true, CUtensorMapL2promotion_enum promotion_mode=CU_TENSOR_MAP_L2_PROMOTION_NONE, typename T>
CUtensorMap create_tensor_map_4D(T* gmem_ptr, int d1, int d2, int d3, int d4, int stride1, int stride2, int stride3) {
    constexpr int smem_stride = BlockMinorSize * sizeof(T);
    static_assert(sizeof(T) == 2 || sizeof(T) == 1);
    static_assert(smem_stride == 32 || smem_stride == 64 || smem_stride == 128);
    
    CUtensorMap tma_map;
    void* gmem_address = (void*)gmem_ptr;
    uint64_t gmem_prob_shape[5] = {(uint64_t)d4, (uint64_t)d3, (uint64_t)d2, (uint64_t)d1, 1};
    uint64_t gmem_prob_stride[5] = {(uint64_t)stride3 * sizeof(T), (uint64_t)stride2 * sizeof(T), (uint64_t)stride1 * sizeof(T), 0, 0};
    uint32_t smem_box_shape[5] = {uint32_t(BlockMinorSize), uint32_t(BlockMajorSize), 1, 1, 1};
    uint32_t smem_box_stride[5] = {1, 1, 1, 1, 1};

    CUresult result = cuTensorMapEncodeTiled(
        &tma_map, (sizeof(T) == 2) ? CU_TENSOR_MAP_DATA_TYPE_BFLOAT16 : CU_TENSOR_MAP_DATA_TYPE_UINT8, 4, gmem_address, gmem_prob_shape,
        gmem_prob_stride, smem_box_shape, smem_box_stride, CU_TENSOR_MAP_INTERLEAVE_NONE,
        (swizzle == false) ? CU_TENSOR_MAP_SWIZZLE_NONE : (smem_stride == 128) ? CU_TENSOR_MAP_SWIZZLE_128B : (smem_stride == 64) ? CU_TENSOR_MAP_SWIZZLE_64B : CU_TENSOR_MAP_SWIZZLE_32B, 
        promotion_mode, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE);

    assert(result == CUDA_SUCCESS);

    return tma_map;
}

// <NT> __cvta_generic_to_shared将通用指针bar转换为共享内存地址. 
// CUDA的内存模型中，不同类型的内存(gmem、smem等)有不同的地址空间.
__device__ __forceinline__ void init_barrier(uint64_t* bar, int thread_count) {
    uint32_t bar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
    asm volatile (
        "mbarrier.init.shared::cta.b64 [%0], %1;\n"
        :: "r"(bar_ptr), "r"(thread_count)
    );
}

// <NT> 确保在指定的共享内存地址bar处，预期的字节数bytes已经准备好.
// 用于多线程或线程块之间的协调，确保在继续执行之前，所有相关的数据都已经写入共享内存。
template <uint32_t bytes>
__device__ __forceinline__ void expect_bytes(uint64_t* bar) {
    uint32_t bar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
    asm volatile ("mbarrier.arrive.expect_tx.shared::cta.b64 _, [%0], %1;\n"
        :: "r"(bar_ptr), "n"(bytes));
}

// <NT> src_tma_map是函数create_tensor_map_4D的返回值，dst是共享内存，通过map将数据从gmem转到smem
template <typename T>
__device__ __forceinline__ void load_async_4D(T *dst, void const* const src_tma_map, uint64_t* bar, int s0, int s1, int s2, int s3) {
    uint64_t tma_ptr  = reinterpret_cast<uint64_t>(src_tma_map);
    uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar));
    uint32_t dst_ptr  = static_cast<uint32_t>(__cvta_generic_to_shared(dst));

    asm volatile (
        "cp.async.bulk.tensor.4d.shared::cluster.global.tile.mbarrier::complete_tx::bytes"
        " [%0], [%1, {%3, %4, %5, %6}], [%2];"
        :
        : "r"(dst_ptr), "l"(tma_ptr), "r"(mbar_ptr),
        "r"(s0), "r"(s1), "r"(s2), "r"(s3)
        : "memory"
    );
}

template <typename T>
__device__ __forceinline__ void store_async_4D(void const* dst_tma_map, T *src, int global_token_idx, int global_head_idx, int global_batch_idx) {
    uint64_t tma_ptr  = reinterpret_cast<uint64_t>(dst_tma_map);
    uint32_t src_ptr  = static_cast<uint32_t>(__cvta_generic_to_shared(src));

    asm volatile (
        "cp.async.bulk.tensor.4d.global.shared::cta.tile.bulk_group"
        " [%0, {%2, %3, %4, %5}], [%1];"
        :
        : "l"(tma_ptr), "r"(src_ptr),
        "n"(0), "r"(global_token_idx), "r"(global_head_idx), "r"(global_batch_idx)
        : "memory"
    );
}

// <NT> mbarrier.try_wait.parity.shared::cta.b64 尝试等待内存屏障，直到满足特定条件
// P1 结果存储在布尔寄存器P1中, @P1 bra.uni DONE如果P1为真（即内存屏障条件满足），则无条件跳转到DONE标签。
// bra.uni LAB_WAIT;：如果P1为假（即内存屏障条件不满足），则无条件跳转回LAB_WAIT标签，继续等待
// kPhaseBit 指定内存屏障的阶段，可以是一个位掩码，用于指定当前线程或线程块需要等待的特定阶段。
// 该wait函数与expect_bytes搭配使用, expect_bytes表示希望数据送达，wait是等待这个希望完成。
__device__ __forceinline__ void wait(uint64_t* bar, int kPhaseBit) {
    uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
    asm volatile (
        "{\n"
        ".reg .pred                P1;\n"
        "LAB_WAIT:\n"
        "mbarrier.try_wait.parity.shared::cta.b64 P1, [%0], %1;\n"
        "@P1                       bra.uni DONE;\n"
        "bra.uni                   LAB_WAIT;\n"
        "DONE:\n"
        "}\n"
        :: "r"(mbar_ptr),
        "r"(kPhaseBit)
    );
}

template <uint32_t count = 1>
__device__ __forceinline__ void arrive(uint64_t* bar) {
    uint32_t mbar_ptr = static_cast<uint32_t>(__cvta_generic_to_shared(bar)); 
    asm volatile (
        "mbarrier.arrive.release.cta.shared::cta.b64 _, [%0], %1;\n"
        :
        : "r"(mbar_ptr), "n"(count)
        : "memory"
    );
}

// <NT> sm90的attention计算cuda kernel (非cutlass)，qk为int8，v为fp8.
// 调用链路：sageattn "sm90"派发 
//          -> sageattn_qk_int8_pv_fp8_cuda_sm90 
//             -> qk_int8_sv_f8_accum_f32_fuse_v_scale_attn_inst_buf 
//                -> qk_int8_sv_f8_attn_kernel
// launch参数: grid(div_ceil(qo_len, CTA_Q), num_qo_heads, batch_size)，CTA_Q是一个block处理的Q维度数量，q总长除以CTA_Q表示Q维度上所需的block数量。
//             加上num_qo_heads和batch_size，组成一个三维的grid。而block是一维128个线程。
// CTA_Q 表示一个block需要处理的q的维度(固定为64)， CTA_K表示一个block需要处理的k的维度(固定为128)；
// Q_GRAN和K_GRAN通常一致，取per_warp和per_thread两种量化方案，见sageattn_qk_int8_pv_fp8_cuda_sm90；
// DTypeOut是bf16或fp16；mask_mode只取是否有因果mask；return_lse通常为false；由接口sageattn进入该函数，则fuse_v_scale为true。
// sm_scale: 如未提供，则取head_dim_og**-0.5，即1/根号(head_dim), 用于缩放点积，以防止在计算 softmax 时数值过大导致的数值不稳定。
//           围绕head_dim进行，是因为稳定性与head_dim大小有关，head_dim较大，那么点积的结果可能会非常大。
// 
// 步骤归纳：
// 1. 
template<uint32_t CTA_Q, uint32_t CTA_K, uint32_t NUM_THREADS, uint32_t head_dim, QuantGranularity Q_GRAN, QuantGranularity K_GRAN, typename DTypeOut, MaskMode mask_mode = MaskMode::kNone, bool return_lse = false, bool fuse_v_scale=false>
__global__ void qk_int8_sv_f8_attn_kernel(const __grid_constant__ CUtensorMap tensorMapQ, 
                                        const __grid_constant__ CUtensorMap tensorMapK,
                                        const __grid_constant__ CUtensorMap tensorMapV,
                                        float *__restrict__ Q_scale, float *__restrict__ K_scale, float *__restrict__ V_scale,
                                        DTypeOut* O, float *__restrict__ Lse, uint32_t stride_bz_o, uint32_t stride_h_o, uint32_t stride_seq_o,
                                        const uint32_t qo_len, const uint32_t kv_len, const uint32_t num_kv_groups,
                                        float sm_scale)
{
  static_assert(NUM_THREADS == 128);
  static_assert(CTA_Q <= CTA_K);
  
  const uint32_t warp_idx = (threadIdx.x % 128) / 32;
  const uint32_t lane_id = threadIdx.x % 32;

  // <NT> 一个block内切分的tile，CTA_Q为64，即Q维度上不再做切分，CTA_K为128则一个block内k维度会分8个tile来处理, head_dim为64或128.
  // 所以有: 
  // num_tiles_q=1,      num_tiles_k=8,         num_tiles_qk_inner=2/4
  // num_tiles_v=4/8,    num_tiles_pv_inner=4
  constexpr uint32_t num_tiles_q = CTA_Q / 64;
  constexpr uint32_t num_tiles_k = CTA_K / 16;
  constexpr uint32_t num_tiles_qk_inner = head_dim / 32;
  constexpr uint32_t num_tiles_v = head_dim / 16;
  constexpr uint32_t num_tiles_pv_inner = CTA_K / 32;

  const uint32_t batch_id = blockIdx.z;
  const uint32_t bx = blockIdx.x;
  const uint32_t head_id = blockIdx.y;
  const uint32_t num_qo_heads = gridDim.y;
  const uint32_t kv_head_id = head_id / num_kv_groups;

  // <NT> 将缩放因子从自然对数空间转换到以 2 为底的对数空间。
  // 后续会直接跟dequant_scale相乘。
  sm_scale *= math::log2e;

  extern __shared__ __align__(128) int8_t smem_[];

  // <NT> sQ[CTA_Q, head_dim], sK[CTA_K, head_dim], sV[head_dim, CTA_K]]
  // sQ*sKt=P[CTA_Q, CTA_K], P*sV=O[CTA_Q, head_dim]
  int8_t *sQ = (int8_t*)smem_;
  int8_t *sK = (int8_t*)(smem_ + CTA_Q * head_dim * sizeof(int8_t));
  int8_t *sV = (int8_t*)(smem_ + CTA_Q * head_dim * sizeof(int8_t) + CTA_K * head_dim * sizeof(int8_t));
  half *sO = (half*)smem_;

  // <NT> 针对wgmma的指令分块，指令取m64n128k32 或 m64n128k32，而一个block涵盖的数据会包含多个指令tile。
  // 所以一个block有多少个指令tile，这里就分多少个元素。
  // RS类型是int32_t，因为是QK的mma是s8*s8=s32；RO取float，因为PV的mma是f8*f8=f32.
  int32_t RS[num_tiles_q][num_tiles_k][8];
  float RO[num_tiles_q][num_tiles_v][8];
  float m[num_tiles_q][2];
  float d[num_tiles_q][2];

  uint32_t q_scale_idx, k_scale_idx;

  if constexpr (Q_GRAN == QuantGranularity::kPerBlock)
  {
    const uint32_t num_block_q = gridDim.x;
    q_scale_idx = batch_id * num_qo_heads * num_block_q + head_id * num_block_q + bx;
  }
  else if constexpr (Q_GRAN == QuantGranularity::kPerWarp)
  {
    const uint32_t num_warp_block_q = gridDim.x * 4;
    q_scale_idx = batch_id * num_qo_heads * num_warp_block_q + head_id * num_warp_block_q + bx * 4 + warp_idx;
  }
  else if constexpr (Q_GRAN == QuantGranularity::kPerThread)
  {
    const uint32_t num_warp_block_q = gridDim.x * 4;
    q_scale_idx = batch_id * num_qo_heads * (num_warp_block_q * 8) + head_id * (num_warp_block_q * 8) + bx * (4 * 8) + warp_idx * 8 + lane_id / 4;
  }

  if constexpr (K_GRAN == QuantGranularity::kPerBlock || K_GRAN == QuantGranularity::kPerWarp)
  {
    const uint32_t num_block_k = div_ceil(kv_len, CTA_K);
    k_scale_idx = batch_id * (num_qo_heads / num_kv_groups) * num_block_k + (head_id / num_kv_groups) * num_block_k;
  }
  else if constexpr (K_GRAN == QuantGranularity::kPerThread)
  {
    const uint32_t num_block_k = div_ceil(kv_len, CTA_K);
    k_scale_idx = batch_id * (num_qo_heads / num_kv_groups) * (num_block_k * 4) + (head_id / num_kv_groups) * (num_block_k * 4) + lane_id % 4;
  }

  constexpr uint32_t k_scale_advance_offset = (K_GRAN == QuantGranularity::kPerBlock || K_GRAN == QuantGranularity::kPerWarp) ? 1 : 4;

  uint32_t Q_idx_lane_base = bx * CTA_Q + warp_idx * 16 + lane_id / 4;

#pragma unroll
  for (uint32_t fq = 0; fq < num_tiles_q; fq++)
  {
    m[fq][0] = -5000000.0f;
    m[fq][1] = -5000000.0f;
    d[fq][0] = 1.0f;
    d[fq][1] = 1.0f;
  }

#pragma unroll
  for (uint32_t fq = 0; fq < num_tiles_q; fq++)
  {
#pragma unroll
    for (uint32_t fv = 0; fv < num_tiles_v; fv++)
    {
#pragma unroll
      for (uint32_t k = 0; k < 8; k++)
      {
        RO[fq][fv][k] = 0.0f;
      }
    }
  }

  __shared__ __align__(8) uint64_t barrier_Q;
  __shared__ __align__(8) uint64_t barrier_K;
  __shared__ __align__(8) uint64_t barrier_V;

  if (threadIdx.x == 0) {
    init_barrier(&barrier_Q, 1);
    init_barrier(&barrier_K, 1);
    init_barrier(&barrier_V, 1);
  }

  __syncthreads();

  // <NT> 同时发起qkv的tma异步拷贝指令，一个block使用一个线程发起。
  // expect_bytes是预期该barrier会有相应的字节数会送达，wait来等待该送达完成。
  // load_async_4D中gmem_prob_shapep[head_dim, seq_len, nhead, batch_size]
  // bx = blockIdx.x;  head_id = blockIdx.y; batch_id = blockIdx.z;  kv_head_id转自head_id
  // 
  // Q：block的xyz涉及到了Q的seq_len / nhead / batch_size，即一次会被全部取出进行计算，
  // 只有head_dim未涉及到，而head_dim最多只有128, 在一个block范围内，
  // 所以Q的读取是在load_async_4D(sQ, &tensorMapQ, &barrier_Q, 0, bx * CTA_Q, head_id, batch_id);一次可完整取出。
  // K: block的yz涉及到了kv_head_id / batch_id，第一维的head_dim同理也在一个block内，剩余seq_len的维度未能完整取出。
  //    即下面的for循环迭代中，需要依次读取seq_len维度上的块，进行分块处理。
  // V：与K类似。
  // 所以一个block需要负责Q的一个tile，并循环取KV在seq_len维度的多个tile的计算。
  // load Q
  // load K0，V0
  // for：
  //    mma(mma(Q,Ki), Vi)
  //    load Ki+1, Vi+1
  //
  // load Q, K, V
  if (threadIdx.x == 0)
  {
    expect_bytes<(CTA_Q * head_dim) * sizeof(int8_t)>(&barrier_Q);
    expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_K);
    expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_V);
    load_async_4D(sQ, &tensorMapQ, &barrier_Q, 0, bx * CTA_Q, head_id, batch_id);
    load_async_4D(sK, &tensorMapK, &barrier_K, 0, 0, kv_head_id, batch_id);
    load_async_4D(sV, &tensorMapV, &barrier_V, 0, 0, kv_head_id, batch_id);
  }

  float q_scale = Q_scale[q_scale_idx];
  float original_sm_scale = sm_scale;

  // <NT> wait后sQ已到位, 可以开始for循环多个KV块的计算。
  // wait for Q
  wait(&barrier_Q, 0);

  const uint32_t num_iterations = div_ceil(
      mask_mode == MaskMode::kCausal
          ? min(kv_len, (bx + 1) * CTA_Q)
          : kv_len,
      CTA_K);

  int p = 1;
  for (uint32_t iter = 1; iter < num_iterations; iter++)
  { 
    // <NT> 区分奇数偶数，1=0^1, 0=1^1，确保对应数据都在同一barrier阶段
    p ^= 1;

    float dequant_scale = q_scale * K_scale[k_scale_idx + (iter - 1) * k_scale_advance_offset];
    sm_scale = original_sm_scale * dequant_scale;

    // wait for K
    wait(&barrier_K, p);

    // compute QK^T
    wgmma::warpgroup_arrive();
#pragma unroll
    // <NT> num_tiles_q为1，该block的该维度刚好是64，不需要针对wgmma再切分。
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
      int8_t *sQ_local = sQ + fq * 64 * head_dim;
      wgmma::wgmma_s8s8s32<CTA_K, 0, head_dim>(RS[fq], sQ_local, sK);
#pragma unroll
      // <NT> num_tiles_qk_inner是2或4。因为head_dim是64或128，Q[CTA_Q, head_dim] * K[CTQ_K, head_dim]，
      // 所以是head_dim充当mma的k，wgmma_s8s8s32内用的是m64n128k32 或 m64n128k32， k取32，需要按k继续分块。
      for (int k_it = 1; k_it < num_tiles_qk_inner; k_it++)
      {
        wgmma::wgmma_s8s8s32<CTA_K, 1, head_dim>(RS[fq], &sQ_local[k_it*32], &sK[k_it*32]);
      }
    }
    // <NT> 提交和同步wg
    wgmma::warpgroup_commit_batch();
    wgmma::warpgroup_wait<0>();

    // <NT> 该轮计算结束，开始预取K的seq_len方向的下一个Tile数据。
    // load K
    if (threadIdx.x == 0)
    {
      expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_K);
      load_async_4D(sK, &tensorMapK, &barrier_K, 0, iter * CTA_K, kv_head_id, batch_id);
    }

    // <NT> RS是QK^T的指令分块计算结果，将其通过__int2float_rz转为fp32。
    // 开始进入online softmax计算的环节。RS_f32是[8,8], 对应一个线程的数据，
    // 一个wg是128个线程，对应一次wgmma的m64n128k32的结果[64,128].
    // convert RS to float
    float RS_f32[num_tiles_q][num_tiles_k][8];
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          RS_f32[fq][fk][k] = __int2float_rz(RS[fq][fk][k]);
        }
      }
    }

    // <NT> 每个线程基于新的QKt输出RS_f32[8,8]，以及历史的 m / d / RO, 共同计算online softmax。
    // 包含 最大值更新；指数和更新；attention out更新；
    // RO: PV结果的累加值
    // m: 最大值，对应fa3中的max_get_scale函数的row_max
    // d: 指数和，对应fa3中的max_get_scale函数的row_sum
    update_mdo<num_tiles_q, num_tiles_k, num_tiles_v, false, true, false>(RS_f32, RO, m, d, sm_scale);

    // accumulate d on thread basis
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unrol
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
        d[fq][0] += (RS_f32[fq][fk][0] + RS_f32[fq][fk][1] + RS_f32[fq][fk][4] + RS_f32[fq][fk][5]);
        d[fq][1] += (RS_f32[fq][fk][2] + RS_f32[fq][fk][3] + RS_f32[fq][fk][6] + RS_f32[fq][fk][7]);
      }
    }

    // <NT> 将fp32的RS转为fp8，准备进入PV的计算。
    uint32_t RS_f8[num_tiles_q][num_tiles_pv_inner][4];
    RS_32_to_8<num_tiles_q, num_tiles_k>(RS_f32, RS_f8);

    // wait for V
    wait(&barrier_V, p);

    float RO_temp[num_tiles_q][num_tiles_v][8];
    wgmma::warpgroup_arrive();
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
      wgmma::wgmma_f8f8f32<head_dim, 0, CTA_K>(RO_temp[fq], RS_f8[fq][0], &sV[0]);
#pragma unroll
      for (uint32_t v_it = 1; v_it < num_tiles_pv_inner; v_it++)
      {
        wgmma::wgmma_f8f8f32<head_dim, 1, CTA_K>(RO_temp[fq], RS_f8[fq][v_it], &sV[v_it * 32]);
      }
    }

    wgmma::warpgroup_commit_batch();
    wgmma::warpgroup_wait<0>();

#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fv = 0; fv < num_tiles_v; fv++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          RO[fq][fv][k] += RO_temp[fq][fv][k];
        }
      }
    }

    // <NT> 这一轮V计算完，马上开始下一轮V的读取
    // load V
    if (threadIdx.x == 0)
    {
      expect_bytes<(CTA_K * head_dim) * sizeof(int8_t)>(&barrier_V);
      load_async_4D(sV, &tensorMapV, &barrier_V, iter * CTA_K, 0, kv_head_id, batch_id);
    }
  }

  { 
    p ^= 1;

    float dequant_scale = q_scale * K_scale[k_scale_idx + (num_iterations - 1) * k_scale_advance_offset];
    sm_scale = original_sm_scale;

    // wait for K
    wait(&barrier_K, p);

    // compute QK^T
    wgmma::warpgroup_arrive();
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
      int8_t *sQ_local = sQ + fq * 64 * head_dim;
      wgmma::wgmma_s8s8s32<CTA_K, 0, head_dim>(RS[fq], sQ_local, sK);
#pragma unroll
      for (int k_it = 1; k_it < num_tiles_qk_inner; k_it++)
      {
        wgmma::wgmma_s8s8s32<CTA_K, 1, head_dim>(RS[fq], &sQ_local[k_it*32], &sK[k_it*32]);
      }
    }
    wgmma::warpgroup_commit_batch();
    wgmma::warpgroup_wait<0>();

    // convert RS to float
    float RS_f32[num_tiles_q][num_tiles_k][8];
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          RS_f32[fq][fk][k] = __int2float_rz(RS[fq][fk][k]) * dequant_scale;
        }
      }
    }

    // masking
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          const uint32_t q_idx = Q_idx_lane_base + fq * 64 + 8 * ((k % 4) / 2);
          const uint32_t k_idx = (num_iterations - 1) * CTA_K + fk * 16 + 2 * (lane_id % 4) + 8 * (k / 4) + k % 2;

          bool is_out_of_bounds;

          if constexpr (mask_mode == MaskMode::kCausal)
          {
            is_out_of_bounds = (k_idx > q_idx) || (k_idx >= kv_len);
          }
          else
          {
            is_out_of_bounds = (k_idx >= kv_len);
          }

          if (is_out_of_bounds)
          {
            RS_f32[fq][fk][k] = -5000000.0f;
          }
        }
      }
    }

    update_mdo<num_tiles_q, num_tiles_k, num_tiles_v, false, true, false>(RS_f32, RO, m, d, sm_scale);

    // accumulate d on thread basis
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unrol
      for (uint32_t fk = 0; fk < num_tiles_k; fk++)
      {
        d[fq][0] += (RS_f32[fq][fk][0] + RS_f32[fq][fk][1] + RS_f32[fq][fk][4] + RS_f32[fq][fk][5]);
        d[fq][1] += (RS_f32[fq][fk][2] + RS_f32[fq][fk][3] + RS_f32[fq][fk][6] + RS_f32[fq][fk][7]);
      }
    }

    uint32_t RS_f8[num_tiles_q][num_tiles_pv_inner][4];
    RS_32_to_8<num_tiles_q, num_tiles_k>(RS_f32, RS_f8);

    // wait for V
    wait(&barrier_V, p);

    float RO_temp[num_tiles_q][num_tiles_v][8];
    wgmma::warpgroup_arrive();
#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
      wgmma::wgmma_f8f8f32<head_dim, 0, CTA_K>(RO_temp[fq], RS_f8[fq][0], &sV[0]);
#pragma unroll
      for (uint32_t v_it = 1; v_it < num_tiles_pv_inner; v_it++)
      {
        wgmma::wgmma_f8f8f32<head_dim, 1, CTA_K>(RO_temp[fq], RS_f8[fq][v_it], &sV[v_it * 32]);
      }
    }

    wgmma::warpgroup_commit_batch();
    wgmma::warpgroup_wait<0>();

#pragma unroll
    for (uint32_t fq = 0; fq < num_tiles_q; fq++)
    {
#pragma unroll
      for (uint32_t fv = 0; fv < num_tiles_v; fv++)
      {
#pragma unroll
        for (uint32_t k = 0; k < 8; k++)
        {
          RO[fq][fv][k] += RO_temp[fq][fv][k];
        }
      }
    }
  }

  normalize_d<num_tiles_q, num_tiles_v, ComputeUnit::kCudaCore>(RO, m, d);

  if constexpr (fuse_v_scale)
  {
    float v_scale[4];
    float *V_scale_base_ptr = V_scale +  batch_id * (num_qo_heads / num_kv_groups) * head_dim + (head_id / num_kv_groups) * head_dim + (lane_id % 4 ) * 2;
  #pragma unroll
    for (uint32_t fv = 0; fv < num_tiles_v; fv++)
    {
      ((float2*)v_scale)[0] = *((float2*)(V_scale_base_ptr + fv * 16));
      ((float2*)v_scale)[1] = *((float2*)(V_scale_base_ptr + fv * 16 + 8));

  #pragma unroll
      for (uint32_t fq = 0; fq < num_tiles_q; fq++)
      {
        RO[fq][fv][0] *= v_scale[0];
        RO[fq][fv][1] *= v_scale[1];
        RO[fq][fv][2] *= v_scale[0];
        RO[fq][fv][3] *= v_scale[1];
        RO[fq][fv][4] *= v_scale[2];
        RO[fq][fv][5] *= v_scale[3];
        RO[fq][fv][6] *= v_scale[2];
        RO[fq][fv][7] *= v_scale[3];
      }
    }
  }

  DTypeOut *O_lane_ptr = O + batch_id * stride_bz_o + head_id * stride_h_o + (bx * CTA_Q + warp_idx * 16 + (lane_id / 4)) * stride_seq_o + (lane_id % 4) * 2 ;
#pragma unroll
  for (uint32_t fq = 0; fq < num_tiles_q; fq++)
  {
#pragma unroll
    for (uint32_t fv = 0; fv < head_dim/16; fv++)
    { 
      if (Q_idx_lane_base + fq * 64 < qo_len)
      {
        if constexpr (std::is_same<DTypeOut, half>::value)
        {
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[0]);
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[2]);
        }
        else
        {
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[0]);
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[2]);  
        }
      }
      
      if (Q_idx_lane_base + fq * 64 + 8 < qo_len)
      {
        if constexpr (std::is_same<DTypeOut, half>::value)
        {
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 * stride_seq_o))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[1]);
          ((half2*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 + 8 * stride_seq_o))[0] = __float22half2_rn(((float2*)(RO[fq][fv]))[3]);
        }
        else
        {
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 * stride_seq_o))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[1]);
          ((nv_bfloat162*)(O_lane_ptr + fq * 64 * stride_seq_o + fv * 16 + 8 + 8 * stride_seq_o))[0] = __float22bfloat162_rn(((float2*)(RO[fq][fv]))[3]);      
        }
      }
    }

    if constexpr (return_lse)
    {
      // only works for CTA_Q = 64
      uint32_t lse_idx = bx * CTA_Q + lane_id / 4 + 8 * (lane_id % 4) + 16 * warp_idx;
      float *lse_lane_ptr = Lse + batch_id * (qo_len * num_qo_heads) + head_id * qo_len + lse_idx;
      uint32_t fq = (lane_id % 4) / 2;
      uint32_t k = (lane_id % 4) % 2;

      if (lse_idx < qo_len && (lane_id % 4) < 2)
      {
        lse_lane_ptr[0] = (math::ptx_log2(d[fq][k]) + m[fq][k]);
      }
    }
  }
}

torch::Tensor qk_int8_sv_f8_accum_f32_attn_inst_buf(
                  torch::Tensor query,
                  torch::Tensor key,
                  torch::Tensor value,
                  torch::Tensor output,
                  torch::Tensor query_scale,
                  torch::Tensor key_scale,
                  int tensor_layout,
                  int is_causal,
                  int qk_quant_gran,
                  float sm_scale,
                  int return_lse)
{
  CHECK_CUDA(query);
  CHECK_CUDA(key);
  CHECK_CUDA(value);
  CHECK_CUDA(output);
  CHECK_CUDA(query_scale);
  CHECK_CUDA(key_scale);

  CHECK_LASTDIM_CONTIGUOUS(query);
  CHECK_LASTDIM_CONTIGUOUS(key);
  CHECK_LASTDIM_CONTIGUOUS(value);
  CHECK_LASTDIM_CONTIGUOUS(output);
  CHECK_CONTIGUOUS(query_scale);
  CHECK_CONTIGUOUS(key_scale);

  CHECK_DTYPE(query, torch::kInt8);
  CHECK_DTYPE(key, torch::kInt8);
  CHECK_DTYPE(value, at::ScalarType::Float8_e4m3fn);
  CHECK_DTYPE(query_scale, torch::kFloat32);
  CHECK_DTYPE(key_scale, torch::kFloat32);

  CHECK_DIMS(query, 4);
  CHECK_DIMS(key, 4);
  CHECK_DIMS(value, 4);
  CHECK_DIMS(output, 4);
  CHECK_DIMS(query_scale, 3);
  CHECK_DIMS(key_scale, 3);

  const int batch_size = query.size(0);
  const int head_dim = query.size(3);

  int stride_bz_q = query.stride(0);
  int stride_bz_k = key.stride(0);
  int stride_bz_v = value.stride(0);
  int stride_bz_o = output.stride(0);

  int qo_len, kv_len, padded_kv_len, num_qo_heads, num_kv_heads;
  int stride_seq_q, stride_h_q, stride_seq_k, stride_h_k, stride_h_v, stride_d_v, stride_seq_o, stride_h_o;

  assert(value.size(0) == batch_size);

  if (tensor_layout == 0)
  {
    qo_len = query.size(1);
    kv_len = key.size(1);
    num_qo_heads = query.size(2);
    num_kv_heads = key.size(2);

    stride_seq_q = query.stride(1);
    stride_h_q = query.stride(2);
    stride_seq_k = key.stride(1);
    stride_h_k = key.stride(2);
    stride_h_v = value.stride(2);
    stride_d_v = value.stride(1);
    stride_seq_o = output.stride(1);
    stride_h_o = output.stride(2);

    CHECK_SHAPE(key, batch_size, kv_len, num_kv_heads, head_dim);
    CHECK_SHAPE(output, batch_size, qo_len, num_qo_heads, head_dim);
    assert(value.size(1) == head_dim);
    assert(value.size(2) == num_kv_heads);
  }
  else
  {
    qo_len = query.size(2);
    kv_len = key.size(2);
    num_qo_heads = query.size(1);
    num_kv_heads = key.size(1);

    stride_seq_q = query.stride(2);
    stride_h_q = query.stride(1);
    stride_seq_k = key.stride(2);
    stride_h_k = key.stride(1);
    stride_h_v = value.stride(1);
    stride_d_v = value.stride(2);
    stride_seq_o = output.stride(2);
    stride_h_o = output.stride(1);

    CHECK_SHAPE(key, batch_size, num_kv_heads, kv_len, head_dim);
    CHECK_SHAPE(output, batch_size, num_qo_heads, qo_len, head_dim);
    assert(value.size(2) == head_dim);
    assert(value.size(1) == num_kv_heads);
  }

  if (num_qo_heads % num_kv_heads != 0) {
    std::ostringstream err_msg;
    err_msg << "num_qo_heads (" << num_qo_heads << ") must be divisible by num_kv_heads (" << num_kv_heads << ")";
    throw std::invalid_argument(err_msg.str());  
  }

  torch::Tensor lse = torch::empty({0});
  if (return_lse)
  {
    lse = torch::empty({batch_size, num_qo_heads, qo_len}, query.options().dtype(torch::kFloat32));
  }

  const int num_kv_groups = num_qo_heads / num_kv_heads;

  auto output_type = output.scalar_type();

  DISPATCH_HEAD_DIM(head_dim, HEAD_DIM, {
    DISPATCH_CAUSAL(is_causal, IS_CAUSAL, {
      DISPATCH_QK_QUANT_GRAN(qk_quant_gran, QK_QUANT_GRAN, {
        DISPATCH_RETURN_LSE(return_lse, RETURN_LSE, {
          DISPATCH_PYTORCH_DTYPE_TO_CTYPE_FP16(output_type, DTypeOut, {
            constexpr int CTA_Q = 64;
            constexpr int CTA_K = 128;
            constexpr int NUM_THREADS = 128;

            constexpr MaskMode mask_mode = IS_CAUSAL ? MaskMode::kCausal : MaskMode::kNone;

            assert(value.size(3) >= div_ceil(kv_len, CTA_K) * CTA_K);

            if constexpr (QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerWarp))
            {
              CHECK_SHAPE(query_scale, batch_size, num_qo_heads, static_cast<long>(div_ceil(qo_len, CTA_Q) * (NUM_THREADS / 32)));
              CHECK_SHAPE(key_scale, batch_size, num_kv_heads, static_cast<long>(div_ceil(kv_len, CTA_K)));
            }
            else if constexpr (QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerThread))
            {
              CHECK_SHAPE(query_scale, batch_size, num_qo_heads, static_cast<long>(div_ceil(qo_len, CTA_Q) * (NUM_THREADS / 32) * 8));
              CHECK_SHAPE(key_scale, batch_size, num_kv_heads, static_cast<long>(div_ceil(kv_len, CTA_K) * 4));    
            }
            else
            {
              static_assert(QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerWarp) || QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerThread), "Unsupported quantization granularity");
            }

            CUtensorMap tma_map_Q = create_tensor_map_4D<CTA_Q, HEAD_DIM>(reinterpret_cast<int8_t*>(query.data_ptr()), batch_size, num_qo_heads, qo_len, HEAD_DIM, stride_bz_q, stride_h_q, stride_seq_q);
            CUtensorMap tma_map_K = create_tensor_map_4D<CTA_K, HEAD_DIM>(reinterpret_cast<int8_t*>(key.data_ptr()), batch_size, num_kv_heads, kv_len, HEAD_DIM, stride_bz_k, stride_h_k, stride_seq_k);
            CUtensorMap tma_map_V = create_tensor_map_4D<HEAD_DIM, CTA_K>(reinterpret_cast<int8_t*>(value.data_ptr()), batch_size, num_kv_heads, HEAD_DIM, value.size(3), stride_bz_v, stride_h_v, stride_d_v);

            auto* kernel = qk_int8_sv_f8_attn_kernel<CTA_Q, CTA_K, NUM_THREADS, HEAD_DIM, static_cast<QuantGranularity>(QK_QUANT_GRAN), static_cast<QuantGranularity>(QK_QUANT_GRAN), DTypeOut, mask_mode, RETURN_LSE, false>;
            size_t sMemSize = CTA_Q * HEAD_DIM * sizeof(int8_t) + CTA_K * HEAD_DIM * sizeof(int8_t) + CTA_K * HEAD_DIM * sizeof(int8_t);
            cudaFuncSetAttribute(
                kernel,
                cudaFuncAttributeMaxDynamicSharedMemorySize, sMemSize);
            
            dim3 grid(div_ceil(qo_len, CTA_Q), num_qo_heads, batch_size);
            kernel<<<grid, NUM_THREADS, sMemSize>>>(
              tma_map_Q,
              tma_map_K,
              tma_map_V,
              reinterpret_cast<float*>(query_scale.data_ptr()),
              reinterpret_cast<float*>(key_scale.data_ptr()),
              nullptr,
              reinterpret_cast<DTypeOut*>(output.data_ptr()),
              (RETURN_LSE) ? reinterpret_cast<float*>(lse.data_ptr()) : nullptr,
              stride_bz_o, stride_h_o, stride_seq_o,
              qo_len, kv_len, num_kv_groups, sm_scale);
          });
        });
      });
    });
  });

  return lse;
}

torch::Tensor qk_int8_sv_f8_accum_f32_fuse_v_scale_attn_inst_buf(
                    torch::Tensor query,
                    torch::Tensor key,
                    torch::Tensor value,
                    torch::Tensor output,
                    torch::Tensor query_scale,
                    torch::Tensor key_scale,
                    torch::Tensor value_scale,
                    int tensor_layout,
                    int is_causal,
                    int qk_quant_gran,
                    float sm_scale,
                    int return_lse)
{
  CHECK_CUDA(query);
  CHECK_CUDA(key);
  CHECK_CUDA(value);
  CHECK_CUDA(output);
  CHECK_CUDA(query_scale);
  CHECK_CUDA(key_scale);
  CHECK_CUDA(value_scale);

  CHECK_LASTDIM_CONTIGUOUS(query);
  CHECK_LASTDIM_CONTIGUOUS(key);
  CHECK_LASTDIM_CONTIGUOUS(value);
  CHECK_LASTDIM_CONTIGUOUS(output);
  CHECK_CONTIGUOUS(query_scale);
  CHECK_CONTIGUOUS(key_scale);
  CHECK_CONTIGUOUS(value_scale);

  CHECK_DTYPE(query, torch::kInt8);
  CHECK_DTYPE(key, torch::kInt8);
  CHECK_DTYPE(value, at::ScalarType::Float8_e4m3fn);
  CHECK_DTYPE(query_scale, torch::kFloat32);
  CHECK_DTYPE(key_scale, torch::kFloat32);
  CHECK_DTYPE(value_scale, torch::kFloat32);

  CHECK_DIMS(query, 4);
  CHECK_DIMS(key, 4);
  CHECK_DIMS(value, 4);
  CHECK_DIMS(output, 4);
  CHECK_DIMS(query_scale, 3);
  CHECK_DIMS(key_scale, 3);
  CHECK_DIMS(value_scale, 3);

  const int batch_size = query.size(0);
  const int head_dim = query.size(3);

  int stride_bz_q = query.stride(0);
  int stride_bz_k = key.stride(0);
  int stride_bz_v = value.stride(0);
  int stride_bz_o = output.stride(0);

  int qo_len, kv_len, padded_kv_len, num_qo_heads, num_kv_heads;
  int stride_seq_q, stride_h_q, stride_seq_k, stride_h_k, stride_h_v, stride_d_v, stride_seq_o, stride_h_o;

  assert(value.size(0) == batch_size);

  if (tensor_layout == 0)
  {
    qo_len = query.size(1);
    kv_len = key.size(1);
    num_qo_heads = query.size(2);
    num_kv_heads = key.size(2);

    stride_seq_q = query.stride(1);
    stride_h_q = query.stride(2);
    stride_seq_k = key.stride(1);
    stride_h_k = key.stride(2);
    stride_h_v = value.stride(2);
    stride_d_v = value.stride(1);
    stride_seq_o = output.stride(1);
    stride_h_o = output.stride(2);

    CHECK_SHAPE(key, batch_size, kv_len, num_kv_heads, head_dim);
    CHECK_SHAPE(output, batch_size, qo_len, num_qo_heads, head_dim);
    assert(value.size(1) == head_dim);
    assert(value.size(2) == num_kv_heads);
  }
  else
  {
    qo_len = query.size(2);
    kv_len = key.size(2);
    num_qo_heads = query.size(1);
    num_kv_heads = key.size(1);

    stride_seq_q = query.stride(2);
    stride_h_q = query.stride(1);
    stride_seq_k = key.stride(2);
    stride_h_k = key.stride(1);
    stride_h_v = value.stride(1);
    stride_d_v = value.stride(2);
    stride_seq_o = output.stride(2);
    stride_h_o = output.stride(1);

    CHECK_SHAPE(key, batch_size, num_kv_heads, kv_len, head_dim);
    CHECK_SHAPE(output, batch_size, num_qo_heads, qo_len, head_dim);
    assert(value.size(2) == head_dim);
    assert(value.size(1) == num_kv_heads);
  }

  if (num_qo_heads % num_kv_heads != 0) {
    std::ostringstream err_msg;
    err_msg << "num_qo_heads (" << num_qo_heads << ") must be divisible by num_kv_heads (" << num_kv_heads << ")";
    throw std::invalid_argument(err_msg.str());  
  }

  torch::Tensor lse = torch::empty({0});
  if (return_lse)
  {
    lse = torch::empty({batch_size, num_qo_heads, qo_len}, query.options().dtype(torch::kFloat32));
  }

  const int num_kv_groups = num_qo_heads / num_kv_heads;

  auto output_dtype = output.scalar_type();

  DISPATCH_HEAD_DIM(head_dim, HEAD_DIM, {
    DISPATCH_CAUSAL(is_causal, IS_CAUSAL, {
      DISPATCH_QK_QUANT_GRAN(qk_quant_gran, QK_QUANT_GRAN, {
        DISPATCH_RETURN_LSE(return_lse, RETURN_LSE, {
          DISPATCH_PYTORCH_DTYPE_TO_CTYPE_FP16(output_dtype, DTypeOut, {
            constexpr int CTA_Q = 64;
            constexpr int CTA_K = 128;
            constexpr int NUM_THREADS = 128;

            constexpr MaskMode mask_mode = IS_CAUSAL ? MaskMode::kCausal : MaskMode::kNone;

            assert(value.size(3) >= div_ceil(kv_len, CTA_K) * CTA_K);

            if constexpr (QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerWarp))
            {
              CHECK_SHAPE(query_scale, batch_size, num_qo_heads, static_cast<long>(div_ceil(qo_len, CTA_Q) * (NUM_THREADS / 32)));
              CHECK_SHAPE(key_scale, batch_size, num_kv_heads, static_cast<long>(div_ceil(kv_len, CTA_K)));
            }
            else if constexpr (QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerThread))
            {
              CHECK_SHAPE(query_scale, batch_size, num_qo_heads, static_cast<long>(div_ceil(qo_len, CTA_Q) * (NUM_THREADS / 32) * 8));
              CHECK_SHAPE(key_scale, batch_size, num_kv_heads, static_cast<long>(div_ceil(kv_len, CTA_K) * 4));    
            }
            else
            {
              static_assert(QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerWarp) || QK_QUANT_GRAN == static_cast<int>(QuantGranularity::kPerThread), "Unsupported quantization granularity");
            }

            CHECK_SHAPE(value_scale, batch_size, num_kv_heads, head_dim);

            CUtensorMap tma_map_Q = create_tensor_map_4D<CTA_Q, HEAD_DIM>(reinterpret_cast<int8_t*>(query.data_ptr()), batch_size, num_qo_heads, qo_len, HEAD_DIM, stride_bz_q, stride_h_q, stride_seq_q);
            CUtensorMap tma_map_K = create_tensor_map_4D<CTA_K, HEAD_DIM>(reinterpret_cast<int8_t*>(key.data_ptr()), batch_size, num_kv_heads, kv_len, HEAD_DIM, stride_bz_k, stride_h_k, stride_seq_k);
            CUtensorMap tma_map_V = create_tensor_map_4D<HEAD_DIM, CTA_K>(reinterpret_cast<int8_t*>(value.data_ptr()), batch_size, num_kv_heads, HEAD_DIM, value.size(3), stride_bz_v, stride_h_v, stride_d_v);

            auto* kernel = qk_int8_sv_f8_attn_kernel<CTA_Q, CTA_K, NUM_THREADS, HEAD_DIM,  static_cast<QuantGranularity>(QK_QUANT_GRAN), static_cast<QuantGranularity>(QK_QUANT_GRAN), DTypeOut, mask_mode, RETURN_LSE, true>;
            size_t sMemSize = CTA_Q * HEAD_DIM * sizeof(int8_t) + CTA_K * HEAD_DIM * sizeof(int8_t) + CTA_K * HEAD_DIM * sizeof(int8_t);
            cudaFuncSetAttribute(
                kernel,
                cudaFuncAttributeMaxDynamicSharedMemorySize, sMemSize);
            
            dim3 grid(div_ceil(qo_len, CTA_Q), num_qo_heads, batch_size);
            kernel<<<grid, NUM_THREADS, sMemSize>>>(
              tma_map_Q,
              tma_map_K,
              tma_map_V,
              reinterpret_cast<float*>(query_scale.data_ptr()),
              reinterpret_cast<float*>(key_scale.data_ptr()),
              reinterpret_cast<float*>(value_scale.data_ptr()),
              reinterpret_cast<DTypeOut*>(output.data_ptr()),
              (RETURN_LSE) ? reinterpret_cast<float*>(lse.data_ptr()) : nullptr,
              stride_bz_o, stride_h_o, stride_seq_o,
              qo_len, kv_len, num_kv_groups, sm_scale);
          });
        });
      });
    });
  });

  return lse;
}