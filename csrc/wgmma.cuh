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

#pragma once
#include <cuda.h>

namespace wgmma{
// <NT> 0x3FFFF是一个18位的掩码，其二进制表示为0011 1111 1111 1111 1111.
// x&0x3FFFF，表示只有低18位的值被保留，其余位都被清零。然后>> 0x4表示右移4位。
__device__ __forceinline__ uint64_t matrix_descriptor_encode(uint64_t x) { return (((x) & 0x3FFFF) >> 0x4); }

// <NT> 生成smem矩阵描述符。smem描述符是一个64位的值，包含了矩阵在共享内存中的地址、维度和步长等信息。
// 这种描述符通常用于与 Tensor Core 指令配合使用. 
// stride表示矩阵的步长（一行的元素个数），T是元素数据类型。
// ptr是smem中矩阵的起始地址，
// __cvta_generic_to_shared将通用指针ptr转换为共享内存指针。
// matrix_descriptor_encode将地址或其他信息编码为矩阵描述符的一部分。
template <int stride, typename T>
__device__ uint64_t make_smem_desc(T* ptr) {
    static_assert(stride == 32 || stride == 64 || stride == 128);
    uint32_t addr = static_cast<uint32_t>(__cvta_generic_to_shared(ptr));
    uint64_t desc = 0x0000000000000000;
    desc |= matrix_descriptor_encode(addr);
    desc |= matrix_descriptor_encode((uint64_t)16) << 16;
    desc |= matrix_descriptor_encode((uint64_t)(8 * stride)) << 32;
    desc |= ((stride == 128) ? 1llu : (stride == 64) ? 2llu : 3llu) << 62;
    return desc;
}

// <NT> 同步一个warp内所有线程
__device__ __forceinline__ void warpgroup_arrive() {
    asm volatile("wgmma.fence.sync.aligned;\n" ::: "memory");
}

// <NT> 将当前 warp group 中所有未提交的 wgmma.mma_async 操作打包成一个新的 wgmma-group.
// 以便后续可以等待这些操作的完成. 一般会先执行该指令，后执行wgmma.wait_group.sync.aligned 进行等待。
__device__ __forceinline__ void warpgroup_commit_batch() {
    asm volatile("wgmma.commit_group.sync.aligned;\n" ::: "memory");
}

// <NT> 使执行该指令的线程等待，直到最近的 wgmma-group 中未完成的操作数量不超过指定的参数 N。
// 当参数 N 为 0 时，线程会等待所有先前提交的 wgmma-group 完成。通常与wgmma.commit_group.sync.aligned搭配使用。
// 如不使用wgmma.commit_group.sync.aligned，直接调用该指令做wg的同步，会导致
// 未定义行为(等待一个不存在的 wgmma-group)和性能问题（浪费时间等待一个空的或不存在的 wgmma-group）。
// 所以应搭配上面的 commit_group 指令使用。
template <int N>
__device__ __forceinline__ void warpgroup_wait() {
    static_assert(N >= 0 && N <= 7, "WGMMA wait: N must be in range [0, 7]");
    asm volatile("wgmma.wait_group.sync.aligned %0;\n" ::"n"(N) : "memory");
}

template<int ScaleD, int ScaleA, int ScaleB, int TransA, int TransB, int BK, typename T>
__device__ __forceinline__ void wgmma_m64n128k16_f16f16f32(float d[][8], T* sA, T* sB) {
    uint64_t desc_a = make_smem_desc<BK*2>(&sA[0]);
    uint64_t desc_b = make_smem_desc<BK*2>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n128k16.f32.f16.f16 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31,  "
        " %32,  %33,  %34,  %35,  %36,  %37,  %38,  %39,  "
        " %40,  %41,  %42,  %43,  %44,  %45,  %46,  %47,  "
        " %48,  %49,  %50,  %51,  %52,  %53,  %54,  %55,  "
        " %56,  %57,  %58,  %59,  %60,  %61,  %62,  %63}, "
        " %64,"
        " %65,"
        " %66,  %67,  %68,  %69,  %70;\n"
        "}\n"
        :   "+f"(d[0][0]), "+f"(d[0][1]), "+f"(d[0][2]), "+f"(d[0][3]), "+f"(d[0][4]), "+f"(d[0][5]), "+f"(d[0][6]), "+f"(d[0][7]),
            "+f"(d[1][0]), "+f"(d[1][1]), "+f"(d[1][2]), "+f"(d[1][3]), "+f"(d[1][4]), "+f"(d[1][5]), "+f"(d[1][6]), "+f"(d[1][7]),
            "+f"(d[2][0]), "+f"(d[2][1]), "+f"(d[2][2]), "+f"(d[2][3]), "+f"(d[2][4]), "+f"(d[2][5]), "+f"(d[2][6]), "+f"(d[2][7]),
            "+f"(d[3][0]), "+f"(d[3][1]), "+f"(d[3][2]), "+f"(d[3][3]), "+f"(d[3][4]), "+f"(d[3][5]), "+f"(d[3][6]), "+f"(d[3][7]),
            "+f"(d[4][0]), "+f"(d[4][1]), "+f"(d[4][2]), "+f"(d[4][3]), "+f"(d[4][4]), "+f"(d[4][5]), "+f"(d[4][6]), "+f"(d[4][7]),
            "+f"(d[5][0]), "+f"(d[5][1]), "+f"(d[5][2]), "+f"(d[5][3]), "+f"(d[5][4]), "+f"(d[5][5]), "+f"(d[5][6]), "+f"(d[5][7]),
            "+f"(d[6][0]), "+f"(d[6][1]), "+f"(d[6][2]), "+f"(d[6][3]), "+f"(d[6][4]), "+f"(d[6][5]), "+f"(d[6][6]), "+f"(d[6][7]),
            "+f"(d[7][0]), "+f"(d[7][1]), "+f"(d[7][2]), "+f"(d[7][3]), "+f"(d[7][4]), "+f"(d[7][5]), "+f"(d[7][6]), "+f"(d[7][7])
        : "l"(desc_a), "l"(desc_b), "n"(int32_t(ScaleD)), "n"(int32_t(ScaleA)),
            "n"(int32_t(ScaleB)), "n"(int32_t(TransA)), "n"(int32_t(TransB)));
}

template<int ScaleD, int ScaleA, int ScaleB, int TransA, int TransB, int BK, typename T>
__device__ __forceinline__ void wgmma_m64n64k16_f16f16f32(float d[][8], T* sA, T* sB) {
    uint64_t desc_a = make_smem_desc<BK*2>(&sA[0]);
    uint64_t desc_b = make_smem_desc<BK*2>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n64k16.f32.f16.f16 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31}, "
        " %32,"
        " %33,"
        " %34,  %35,  %36,  %37,  %38;\n"
        "}\n"
        :   "+f"(d[0][0]), "+f"(d[0][1]), "+f"(d[0][2]), "+f"(d[0][3]), "+f"(d[0][4]), "+f"(d[0][5]), "+f"(d[0][6]), "+f"(d[0][7]),
            "+f"(d[1][0]), "+f"(d[1][1]), "+f"(d[1][2]), "+f"(d[1][3]), "+f"(d[1][4]), "+f"(d[1][5]), "+f"(d[1][6]), "+f"(d[1][7]),
            "+f"(d[2][0]), "+f"(d[2][1]), "+f"(d[2][2]), "+f"(d[2][3]), "+f"(d[2][4]), "+f"(d[2][5]), "+f"(d[2][6]), "+f"(d[2][7]),
            "+f"(d[3][0]), "+f"(d[3][1]), "+f"(d[3][2]), "+f"(d[3][3]), "+f"(d[3][4]), "+f"(d[3][5]), "+f"(d[3][6]), "+f"(d[3][7])
        : "l"(desc_a), "l"(desc_b), "n"(int32_t(ScaleD)), "n"(int32_t(ScaleA)),
            "n"(int32_t(ScaleB)), "n"(int32_t(TransA)), "n"(int32_t(TransB)));
}

template<int ScaleD, int ScaleA, int ScaleB, int TransA, int TransB, int BK, typename T>
__device__ __forceinline__ void wgmma_m64n128k16_f16f16f32(float d[][8], uint32_t RA[], T* sB) {
    uint64_t desc_b = make_smem_desc<BK*2>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n128k16.f32.f16.f16 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31,  "
        " %32,  %33,  %34,  %35,  %36,  %37,  %38,  %39,  "
        " %40,  %41,  %42,  %43,  %44,  %45,  %46,  %47,  "
        " %48,  %49,  %50,  %51,  %52,  %53,  %54,  %55,  "
        " %56,  %57,  %58,  %59,  %60,  %61,  %62,  %63}, "
        "{%64,  %65,  %66,  %67}, "
        " %68,"
        " %69,  %70,  %71, %72;\n"
        "}\n"
        :   "+f"(d[0][0]), "+f"(d[0][1]), "+f"(d[0][2]), "+f"(d[0][3]), "+f"(d[0][4]), "+f"(d[0][5]), "+f"(d[0][6]), "+f"(d[0][7]),
            "+f"(d[1][0]), "+f"(d[1][1]), "+f"(d[1][2]), "+f"(d[1][3]), "+f"(d[1][4]), "+f"(d[1][5]), "+f"(d[1][6]), "+f"(d[1][7]),
            "+f"(d[2][0]), "+f"(d[2][1]), "+f"(d[2][2]), "+f"(d[2][3]), "+f"(d[2][4]), "+f"(d[2][5]), "+f"(d[2][6]), "+f"(d[2][7]),
            "+f"(d[3][0]), "+f"(d[3][1]), "+f"(d[3][2]), "+f"(d[3][3]), "+f"(d[3][4]), "+f"(d[3][5]), "+f"(d[3][6]), "+f"(d[3][7]),
            "+f"(d[4][0]), "+f"(d[4][1]), "+f"(d[4][2]), "+f"(d[4][3]), "+f"(d[4][4]), "+f"(d[4][5]), "+f"(d[4][6]), "+f"(d[4][7]),
            "+f"(d[5][0]), "+f"(d[5][1]), "+f"(d[5][2]), "+f"(d[5][3]), "+f"(d[5][4]), "+f"(d[5][5]), "+f"(d[5][6]), "+f"(d[5][7]),
            "+f"(d[6][0]), "+f"(d[6][1]), "+f"(d[6][2]), "+f"(d[6][3]), "+f"(d[6][4]), "+f"(d[6][5]), "+f"(d[6][6]), "+f"(d[6][7]),
            "+f"(d[7][0]), "+f"(d[7][1]), "+f"(d[7][2]), "+f"(d[7][3]), "+f"(d[7][4]), "+f"(d[7][5]), "+f"(d[7][6]), "+f"(d[7][7])
        :   "r"(RA[0]), "r"(RA[1]), "r"(RA[2]), "r"(RA[3]),
            "l"(desc_b), "n"(int32_t(ScaleD)), "n"(int32_t(ScaleA)),
            "n"(int32_t(ScaleB)), "n"(int32_t(TransB)));
}

template<int ScaleD, int ScaleA, int ScaleB, int TransA, int TransB, int BK, typename T>
__device__ __forceinline__ void wgmma_m64n64k16_f16f16f32(float d[][8], uint32_t RA[], T* sB) {
    uint64_t desc_b = make_smem_desc<BK*2>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n64k16.f32.f16.f16 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31}, "
        "{%32,  %33,  %34,  %35}, "
        " %36,"
        " %37,  %38,  %39, %40;\n"
        "}\n"
        :   "+f"(d[0][0]), "+f"(d[0][1]), "+f"(d[0][2]), "+f"(d[0][3]), "+f"(d[0][4]), "+f"(d[0][5]), "+f"(d[0][6]), "+f"(d[0][7]),
            "+f"(d[1][0]), "+f"(d[1][1]), "+f"(d[1][2]), "+f"(d[1][3]), "+f"(d[1][4]), "+f"(d[1][5]), "+f"(d[1][6]), "+f"(d[1][7]),
            "+f"(d[2][0]), "+f"(d[2][1]), "+f"(d[2][2]), "+f"(d[2][3]), "+f"(d[2][4]), "+f"(d[2][5]), "+f"(d[2][6]), "+f"(d[2][7]),
            "+f"(d[3][0]), "+f"(d[3][1]), "+f"(d[3][2]), "+f"(d[3][3]), "+f"(d[3][4]), "+f"(d[3][5]), "+f"(d[3][6]), "+f"(d[3][7])
        :   "r"(RA[0]), "r"(RA[1]), "r"(RA[2]), "r"(RA[3]),
            "l"(desc_b), "n"(int32_t(ScaleD)), "n"(int32_t(ScaleA)),
            "n"(int32_t(ScaleB)), "n"(int32_t(TransB)));
}

template<int ScaleD, int BK, typename T>
__device__ __forceinline__ void wgmma_m64n64k32_f8f8f32(float d[][8], uint32_t RA[], T* sB) {
    uint64_t desc_b = make_smem_desc<BK>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n64k32.f32.e4m3.e4m3 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31}, "
        "{%32,  %33,  %34,  %35}, "
        " %36,"
        " %37,"
        " %38,  %39;\n"
        "}\n"
        :   "+f"(d[0][0]), "+f"(d[0][1]), "+f"(d[0][2]), "+f"(d[0][3]), "+f"(d[0][4]), "+f"(d[0][5]), "+f"(d[0][6]), "+f"(d[0][7]),
            "+f"(d[1][0]), "+f"(d[1][1]), "+f"(d[1][2]), "+f"(d[1][3]), "+f"(d[1][4]), "+f"(d[1][5]), "+f"(d[1][6]), "+f"(d[1][7]),
            "+f"(d[2][0]), "+f"(d[2][1]), "+f"(d[2][2]), "+f"(d[2][3]), "+f"(d[2][4]), "+f"(d[2][5]), "+f"(d[2][6]), "+f"(d[2][7]),
            "+f"(d[3][0]), "+f"(d[3][1]), "+f"(d[3][2]), "+f"(d[3][3]), "+f"(d[3][4]), "+f"(d[3][5]), "+f"(d[3][6]), "+f"(d[3][7])
        :   "r"(RA[0]), "r"(RA[1]), "r"(RA[2]), "r"(RA[3]),
            "l"(desc_b), "n"(int32_t(ScaleD)),
            "n"(1), "n"(1));
}

template<int ScaleD, int BK, typename T>
__device__ __forceinline__ void wgmma_m64n128k32_f8f8f32(float d[][8], uint32_t RA[], T* sB) {
    uint64_t desc_b = make_smem_desc<BK>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n128k32.f32.e4m3.e4m3 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31,  "
        " %32,  %33,  %34,  %35,  %36,  %37,  %38,  %39,  "
        " %40,  %41,  %42,  %43,  %44,  %45,  %46,  %47,  "
        " %48,  %49,  %50,  %51,  %52,  %53,  %54,  %55,  "
        " %56,  %57,  %58,  %59,  %60,  %61,  %62,  %63}, "
        "{%64,  %65,  %66,  %67}, "
        " %68,"
        " %69,"
        " %70,  %71;\n"
        "}\n"
        :   "+f"(d[0][0]), "+f"(d[0][1]), "+f"(d[0][2]), "+f"(d[0][3]), "+f"(d[0][4]), "+f"(d[0][5]), "+f"(d[0][6]), "+f"(d[0][7]),
            "+f"(d[1][0]), "+f"(d[1][1]), "+f"(d[1][2]), "+f"(d[1][3]), "+f"(d[1][4]), "+f"(d[1][5]), "+f"(d[1][6]), "+f"(d[1][7]),
            "+f"(d[2][0]), "+f"(d[2][1]), "+f"(d[2][2]), "+f"(d[2][3]), "+f"(d[2][4]), "+f"(d[2][5]), "+f"(d[2][6]), "+f"(d[2][7]),
            "+f"(d[3][0]), "+f"(d[3][1]), "+f"(d[3][2]), "+f"(d[3][3]), "+f"(d[3][4]), "+f"(d[3][5]), "+f"(d[3][6]), "+f"(d[3][7]),
            "+f"(d[4][0]), "+f"(d[4][1]), "+f"(d[4][2]), "+f"(d[4][3]), "+f"(d[4][4]), "+f"(d[4][5]), "+f"(d[4][6]), "+f"(d[4][7]),
            "+f"(d[5][0]), "+f"(d[5][1]), "+f"(d[5][2]), "+f"(d[5][3]), "+f"(d[5][4]), "+f"(d[5][5]), "+f"(d[5][6]), "+f"(d[5][7]),
            "+f"(d[6][0]), "+f"(d[6][1]), "+f"(d[6][2]), "+f"(d[6][3]), "+f"(d[6][4]), "+f"(d[6][5]), "+f"(d[6][6]), "+f"(d[6][7]),
            "+f"(d[7][0]), "+f"(d[7][1]), "+f"(d[7][2]), "+f"(d[7][3]), "+f"(d[7][4]), "+f"(d[7][5]), "+f"(d[7][6]), "+f"(d[7][7])
        :   "r"(RA[0]), "r"(RA[1]), "r"(RA[2]), "r"(RA[3]),
            "l"(desc_b), "n"(int32_t(ScaleD)),
            "n"(1), "n"(1));
}

// <NT> s8[64,32] * s8[32,128] = s32[64, 128] => 
// 一个wg共4*32=128个线程，一个线程对应d[8,8]的输出，拼凑出完整的输出s32[64, 128].
// BK是head_dim是64或128，也是blockTile计算中的K，对应取出的矩阵的stride将会是64或128.
template<int ScaleD, int BK, typename T>
__device__ void wgmma_m64n128k32_s8s8s32(int32_t d[][8], T* sA, T* sB) {
    uint64_t desc_a = make_smem_desc<BK>(&sA[0]);
    uint64_t desc_b = make_smem_desc<BK>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n128k32.s32.s8.s8 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31,  "
        " %32,  %33,  %34,  %35,  %36,  %37,  %38,  %39,  "
        " %40,  %41,  %42,  %43,  %44,  %45,  %46,  %47,  "
        " %48,  %49,  %50,  %51,  %52,  %53,  %54,  %55,  "
        " %56,  %57,  %58,  %59,  %60,  %61,  %62,  %63}, "
        " %64,"
        " %65,"
        " %66;\n"
        "}\n"
        : "+r"(d[0][0]), "+r"(d[0][1]), "+r"(d[0][2]), "+r"(d[0][3]), "+r"(d[0][4]), "+r"(d[0][5]), "+r"(d[0][6]), "+r"(d[0][7]),
          "+r"(d[1][0]), "+r"(d[1][1]), "+r"(d[1][2]), "+r"(d[1][3]), "+r"(d[1][4]), "+r"(d[1][5]), "+r"(d[1][6]), "+r"(d[1][7]),
          "+r"(d[2][0]), "+r"(d[2][1]), "+r"(d[2][2]), "+r"(d[2][3]), "+r"(d[2][4]), "+r"(d[2][5]), "+r"(d[2][6]), "+r"(d[2][7]),
          "+r"(d[3][0]), "+r"(d[3][1]), "+r"(d[3][2]), "+r"(d[3][3]), "+r"(d[3][4]), "+r"(d[3][5]), "+r"(d[3][6]), "+r"(d[3][7]),
          "+r"(d[4][0]), "+r"(d[4][1]), "+r"(d[4][2]), "+r"(d[4][3]), "+r"(d[4][4]), "+r"(d[4][5]), "+r"(d[4][6]), "+r"(d[4][7]),
          "+r"(d[5][0]), "+r"(d[5][1]), "+r"(d[5][2]), "+r"(d[5][3]), "+r"(d[5][4]), "+r"(d[5][5]), "+r"(d[5][6]), "+r"(d[5][7]),
          "+r"(d[6][0]), "+r"(d[6][1]), "+r"(d[6][2]), "+r"(d[6][3]), "+r"(d[6][4]), "+r"(d[6][5]), "+r"(d[6][6]), "+r"(d[6][7]),
          "+r"(d[7][0]), "+r"(d[7][1]), "+r"(d[7][2]), "+r"(d[7][3]), "+r"(d[7][4]), "+r"(d[7][5]), "+r"(d[7][6]), "+r"(d[7][7])
        : "l"(desc_a), "l"(desc_b), "n"(int32_t(ScaleD)));
}

template<int ScaleD, int BK, typename T>
__device__ void wgmma_m64n64k32_s8s8s32(int32_t d[][8], T* sA, T* sB) {
    uint64_t desc_a = make_smem_desc<BK>(&sA[0]);
    uint64_t desc_b = make_smem_desc<BK>(&sB[0]);
    asm volatile(
        "{\n"
        "wgmma.mma_async.sync.aligned.m64n64k32.s32.s8.s8 "
        "{%0,   %1,   %2,   %3,   %4,   %5,   %6,   %7,   "
        " %8,   %9,   %10,  %11,  %12,  %13,  %14,  %15,  "
        " %16,  %17,  %18,  %19,  %20,  %21,  %22,  %23,  "
        " %24,  %25,  %26,  %27,  %28,  %29,  %30,  %31},"
        " %32,"
        " %33,"
        " %34;\n"
        "}\n"
        : "+r"(d[0][0]), "+r"(d[0][1]), "+r"(d[0][2]), "+r"(d[0][3]), "+r"(d[0][4]), "+r"(d[0][5]), "+r"(d[0][6]), "+r"(d[0][7]),
          "+r"(d[1][0]), "+r"(d[1][1]), "+r"(d[1][2]), "+r"(d[1][3]), "+r"(d[1][4]), "+r"(d[1][5]), "+r"(d[1][6]), "+r"(d[1][7]),
          "+r"(d[2][0]), "+r"(d[2][1]), "+r"(d[2][2]), "+r"(d[2][3]), "+r"(d[2][4]), "+r"(d[2][5]), "+r"(d[2][6]), "+r"(d[2][7]),
          "+r"(d[3][0]), "+r"(d[3][1]), "+r"(d[3][2]), "+r"(d[3][3]), "+r"(d[3][4]), "+r"(d[3][5]), "+r"(d[3][6]), "+r"(d[3][7])
        : "l"(desc_a), "l"(desc_b), "n"(int32_t(ScaleD)));
}

template<int WGMMA_N, int ScaleD, int ScaleA, int ScaleB, int TransA, int TransB, int BK, typename DTypeIn, typename T>
__device__ __forceinline__ void wgmma_f16f16f32(float d[WGMMA_N/16][8], T* sA, T* sB) {
    static_assert(std::is_same<DTypeIn, half>::value);

    static_assert(WGMMA_N == 128 || WGMMA_N == 64);
    if constexpr (WGMMA_N == 128) {
        wgmma_m64n128k16_f16f16f32<ScaleD, ScaleA, ScaleB, TransA, TransB, BK>(d, sA, sB);
    }
    else if constexpr (WGMMA_N == 64) {
        wgmma_m64n64k16_f16f16f32<ScaleD, ScaleA, ScaleB, TransA, TransB, BK>(d, sA, sB);
    }
}

// <NT> 按WGMMA_N派发m64n128k32和m64n64k32的wgmma指令
template<int WGMMA_N, int ScaleD, int BK, typename T>
__device__ __forceinline__ void wgmma_s8s8s32(int32_t d[WGMMA_N/16][8], T* sA, T* sB) {
    static_assert(WGMMA_N == 128 || WGMMA_N == 64);
    if constexpr (WGMMA_N == 128) {
        wgmma_m64n128k32_s8s8s32<ScaleD, BK>(d, sA, sB);
    }
    else if constexpr (WGMMA_N == 64) {
        wgmma_m64n64k32_s8s8s32<ScaleD, BK>(d, sA, sB);
    }
}

template<int WGMMA_N, int ScaleD, int BK, typename T>
__device__ __forceinline__ void wgmma_f8f8f32(float d[][8], uint32_t* RA, T* sB) {
    static_assert(WGMMA_N == 128 || WGMMA_N == 64);
    if constexpr (WGMMA_N == 128) {
        wgmma_m64n128k32_f8f8f32<ScaleD, BK>(d, RA, sB);
    }
    else if constexpr (WGMMA_N == 64) {
        wgmma_m64n64k32_f8f8f32<ScaleD, BK>(d, RA, sB);
    }
}

} // namespace wgmma