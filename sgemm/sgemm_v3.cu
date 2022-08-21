// optimize sgemm

#include <stdio.h>
#include <stdlib.h>

// CUDA runtime
#include <cuda_runtime.h>
#include <cublas_v2.h>

// cal offset from row col and ld , in row-major matrix, ld is the width of the matrix
#define OFFSET(row, col, ld) ((row) * (ld) + (col))

// transfer float4
#define FETCH_FLOAT4(pointer) (reinterpret_cast<float4*>(&(pointer))[0])

#define checkCudaErrors(func)				\
{									\
    cudaError_t e = (func);			\
    if(e != cudaSuccess)						                \
        printf ("%s %d CUDA: %s\n", __FILE__,  __LINE__, cudaGetErrorString(e));		\
}

// K: ldA
// N: ldB
template <
    const int BLOCK_SIZE_M /* height of block of C that each thread block calculate //128 */,  
    const int BLOCK_SIZE_K,  // width of block of A that each thread block load into shared memory //8
    const int BLOCK_SIZE_N,  // width of block of C that each thread block calculate //128
    const int THREAD_SIZE_Y, // height of block of C that each thread calculate //8
    const int THREAD_SIZE_X,  // width of block of C that each thread calculate //8
    const bool ENABLE_DOUBLE_BUFFER // whether enable double buffering or not
    > 
__global__ void Sgemm( 
    float * __restrict__ A,
    float * __restrict__ B,
    float * __restrict__ C, 
    const int M,
    const int N,
    const int K) {
    // Block index
    int bx = blockIdx.x;
    int by = blockIdx.y;

    // Thread index
    int tx = threadIdx.x;
    int ty = threadIdx.y;
    
    // the threads number in Block of X,Y
    const int THREAD_X_PER_BLOCK = BLOCK_SIZE_N / THREAD_SIZE_X;//BlkDim.x 16
    const int THREAD_Y_PER_BLOCK = BLOCK_SIZE_M / THREAD_SIZE_Y;//BlkDim.y 16
    const int THREAD_NUM_PER_BLOCK = THREAD_X_PER_BLOCK * THREAD_Y_PER_BLOCK;//BTBT 一个blk有256=16*16个thrd

    // thread id in cur Block
    const int tid = ty * THREAD_X_PER_BLOCK + tx;

    // shared memory
    __shared__ float As[2][BLOCK_SIZE_K][BLOCK_SIZE_M];//[2][8][128]
    __shared__ float Bs[2][BLOCK_SIZE_K][BLOCK_SIZE_N];
    // registers for C
    float accum[THREAD_SIZE_Y][THREAD_SIZE_X];//[128][128]
    #pragma unroll
    for(int i=0; i<THREAD_SIZE_Y; i++){
        #pragma unroll
        for(int j=0; j<THREAD_SIZE_X; j++){
            accum[i][j]=0.0;
        }
    }
    
    // registers load global memory
    const int ldg_num_a = BLOCK_SIZE_M * BLOCK_SIZE_K / (THREAD_NUM_PER_BLOCK * 4);//BTBT ??? 4是指float4?
    const int ldg_num_b = BLOCK_SIZE_K * BLOCK_SIZE_N / (THREAD_NUM_PER_BLOCK * 4);
    float ldg_a_reg[4*ldg_num_a];//BTBT (128*8)/256=4 每个thrd负责取多少glb的elem
    float ldg_b_reg[4*ldg_num_b];

    // threads number in one row (in BlkTil) //BTBT ??? 除4啥意思???每个thrd取一次,每次一个float4?
    const int A_TILE_THREAD_PER_ROW = BLOCK_SIZE_K / 4;//BTBT 每thrd每次取float4的话,每个blk的一行elem需要多少thrd就能一次取完 8/4=2
    const int B_TILE_THREAD_PER_ROW = BLOCK_SIZE_N / 4;

    // row number and col number that needs to be loaded by this thread
    const int A_TILE_ROW_START = tid / A_TILE_THREAD_PER_ROW;//BTBT 该thrd在BlkTIl内是第几行
    const int B_TILE_ROW_START = tid / B_TILE_THREAD_PER_ROW;

    const int A_TILE_COL = tid % A_TILE_THREAD_PER_ROW * 4; //BTBT 该thrd在BlkTIl内是第几列
    const int B_TILE_COL = tid % B_TILE_THREAD_PER_ROW * 4;

    // row stride that thread uses to load multiple rows of a tile
    const int A_TILE_ROW_STRIDE = THREAD_NUM_PER_BLOCK / A_TILE_THREAD_PER_ROW;//BTBT 一个BlkTil内有多少thrd row 256/2=128
    const int B_TILE_ROW_STRIDE = THREAD_NUM_PER_BLOCK / B_TILE_THREAD_PER_ROW;

    A = &A[(BLOCK_SIZE_M * by)* K];//BTBT 指针移动到该BlkTil在A中的左上角起点
    B = &B[BLOCK_SIZE_N * bx];//BTBT 指针移动到该BlkTil在B中的左上角起点

    //transfer first tile from global mem to shared mem
    // load A from global memory to shared memory
    #pragma unroll
    for ( int i = 0 ; i < BLOCK_SIZE_M ; i += A_TILE_ROW_STRIDE) {//BTBT 当前场景下共256thrd,每行2thrd,有128行,256thrd每thrd取一个float4填入SMEM,刚好填满As[0]which is [4*2][128]
        int ldg_index = i / A_TILE_ROW_STRIDE * 4;
        FETCH_FLOAT4(ldg_a_reg[ldg_index]) = FETCH_FLOAT4(A[OFFSET(  //OFFSET(row, col, ld) ((row) * (ld) + (col))
            A_TILE_ROW_START + i, // row (tid/A_TILE_THREAD_PER_ROW=tid/2)+i
            A_TILE_COL, // col tid % A_TILE_THREAD_PER_ROW * 4
            K )]);
        As[0][A_TILE_COL][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index]; //BTBT ??? 写SMEM是否有bank conflic
        As[0][A_TILE_COL+1][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index+1];
        As[0][A_TILE_COL+2][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index+2];
        As[0][A_TILE_COL+3][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index+3];
    }
    // load B from global memory to shared memory
    #pragma unroll
    for ( int i = 0 ; i < BLOCK_SIZE_K; i += B_TILE_ROW_STRIDE) {
        FETCH_FLOAT4(Bs[0][B_TILE_ROW_START + i][B_TILE_COL]) = FETCH_FLOAT4(B[OFFSET(
                B_TILE_ROW_START + i, // row
                B_TILE_COL, // col
                N )]);
    }
    __syncthreads();

    // registers for A and B SMEM
    float frag_a[2][THREAD_SIZE_Y];
    float frag_b[2][THREAD_SIZE_X];

    //load index of the tile
    const int warp_id = tid / 32;
    const int lane_id = tid % 32;
    const int tile_index = (warp_id%4)*16 + (lane_id/16)*8 + (lane_id%2)*4;

    // load A from shared memory to register
    FETCH_FLOAT4(frag_a[0][0]) = FETCH_FLOAT4(As[0][0][tile_index]);//BTBT 参考https://zhuanlan.zhihu.com/p/481600052 ,这里是取128的前半,下面取后半
    FETCH_FLOAT4(frag_a[0][4]) = FETCH_FLOAT4(As[0][0][tile_index + 64]);
    // load B from shared memory to register
    FETCH_FLOAT4(frag_b[0][0]) = FETCH_FLOAT4(Bs[0][0][tile_index]);
    FETCH_FLOAT4(frag_b[0][4]) = FETCH_FLOAT4(Bs[0][0][tile_index + 64]);

    int write_stage_idx = 1;
    int tile_idx = 0;
    do{
        tile_idx += BLOCK_SIZE_K;
        // load next tile from global mem
        if(tile_idx< K){
            #pragma unroll
            for ( int i = 0 ; i < BLOCK_SIZE_M ; i += A_TILE_ROW_STRIDE) {
                int ldg_index = i / A_TILE_ROW_STRIDE * 4;
                FETCH_FLOAT4(ldg_a_reg[ldg_index]) = FETCH_FLOAT4(A[OFFSET(
                    A_TILE_ROW_START + i, // row
                    A_TILE_COL + tile_idx, // col
                    K )]);
            }
            #pragma unroll
            for ( int i = 0 ; i < BLOCK_SIZE_K; i += B_TILE_ROW_STRIDE) {
                int ldg_index = i / A_TILE_ROW_STRIDE * 4;
                FETCH_FLOAT4(ldg_b_reg[ldg_index]) = FETCH_FLOAT4(B[OFFSET(
                    tile_idx + B_TILE_ROW_START + i, // row
                    B_TILE_COL, // col
                    N )]);
            }
        }

        int load_stage_idx = write_stage_idx ^ 1;
        int next_stage_flag = load_stage_idx;

        #pragma unroll
        for(int j=0; j<BLOCK_SIZE_K; ++j){
            // load next tile from shared mem to register //BTBT ??? 这个load和write的次序貌似错了?tile_index的计算对于A,B来说应该不一样,否则无法计算完整矩阵?这个文件问题较多,不建议看
            next_stage_flag = (j==BLOCK_SIZE_K-1)?load_stage_idx:write_stage_idx;
            // load A from shared memory to register
            FETCH_FLOAT4(frag_a[(j+1)%2][0]) = FETCH_FLOAT4(As[next_stage_flag][(j+1)%BLOCK_SIZE_K][tile_index]);
            FETCH_FLOAT4(frag_a[(j+1)%2][4]) = FETCH_FLOAT4(As[next_stage_flag][(j+1)%BLOCK_SIZE_K][tile_index + 64]);
            // load B from shared memory to register
            FETCH_FLOAT4(frag_b[(j+1)%2][0]) = FETCH_FLOAT4(Bs[next_stage_flag][(j+1)%BLOCK_SIZE_K][tile_index]);
            FETCH_FLOAT4(frag_b[(j+1)%2][4]) = FETCH_FLOAT4(Bs[next_stage_flag][(j+1)%BLOCK_SIZE_K][tile_index + 64]);
            // compute C THREAD_SIZE_X x THREAD_SIZE_Y
            #pragma unroll
            for (int thread_y = 0; thread_y < THREAD_SIZE_Y; ++thread_y) {
                #pragma unroll
                for (int thread_x = 0; thread_x < THREAD_SIZE_X; ++thread_x) {
                    accum[thread_y][thread_x] += frag_a[j%2][thread_y] * frag_b[j%2][thread_x];
                }
            }
        }

        if(tile_idx < K){
            #pragma unroll
            for ( int i = 0 ; i < BLOCK_SIZE_M ; i += A_TILE_ROW_STRIDE) {
                int ldg_index = i / A_TILE_ROW_STRIDE * 4;
                As[write_stage_idx][A_TILE_COL][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index];
                As[write_stage_idx][A_TILE_COL+1][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index+1];
                As[write_stage_idx][A_TILE_COL+2][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index+2];
                As[write_stage_idx][A_TILE_COL+3][A_TILE_ROW_START + i]=ldg_a_reg[ldg_index+3];
            }
            // load B from global memory to shared memory
            #pragma unroll
            for ( int i = 0 ; i < BLOCK_SIZE_K; i += B_TILE_ROW_STRIDE) {
                int ldg_index = i / A_TILE_ROW_STRIDE * 4;
                FETCH_FLOAT4(Bs[write_stage_idx][B_TILE_ROW_START + i][B_TILE_COL]) = FETCH_FLOAT4(ldg_b_reg[ldg_index]);
            }
            // use double buffer, only need one sync
            __syncthreads();
            // switch
            write_stage_idx ^= 1;
        }
    }while(tile_idx< K);

    //store C00 block
    for(int i=0; i<4; i++){
      FETCH_FLOAT4(C[OFFSET(
        BLOCK_SIZE_M * by + ty * 4 + i,
        BLOCK_SIZE_N * bx + tx * 4,
        N)]) = FETCH_FLOAT4(accum[i][0]);
    }
    //store C01 block
    for(int i=0; i<4; i++){
      FETCH_FLOAT4(C[OFFSET(
        BLOCK_SIZE_M * by + ty * 4 + i,
        BLOCK_SIZE_N * bx + tx * 4 + 64,
        N)]) = FETCH_FLOAT4(accum[i][4]);
    }
    //store C10 block
    for(int i=0; i<4; i++){
      FETCH_FLOAT4(C[OFFSET(
        BLOCK_SIZE_M * by + ty * 4 + i + 64,
        BLOCK_SIZE_N * bx + tx * 4,
        N)]) = FETCH_FLOAT4(accum[i+4][0]);
    }
    //store C11 block
    for(int i=0; i<4; i++){
      FETCH_FLOAT4(C[OFFSET(
        BLOCK_SIZE_M * by + ty * 4 + i+ 64,
        BLOCK_SIZE_N * bx + tx * 4 + 64,
        N)]) = FETCH_FLOAT4(accum[i+4][4]);
    }
}

int main(int argc, char** argv) {
    if (argc != 4) {
        printf("usage: ./main [M] [K] [N]\n");
        exit(0);
    }
    size_t M = atoi(argv[1]);
    size_t K = atoi(argv[2]);
    size_t N = atoi(argv[3]);

    size_t bytes_A = sizeof(float) * M * K;
    size_t bytes_B = sizeof(float) * K * N;
    size_t bytes_C = sizeof(float) * M * N;
    float* h_A = (float*)malloc(bytes_A);
    float* h_B = (float*)malloc(bytes_B);
    float* h_C = (float*)malloc(bytes_C);
    float* h_C1 = (float*)malloc(bytes_C);

    float* d_A;
    float* d_B;
    float* d_C;

    checkCudaErrors(cudaMalloc(&d_A, bytes_A));
    checkCudaErrors(cudaMalloc(&d_B, bytes_B));
    checkCudaErrors(cudaMalloc(&d_C, bytes_C));
    double msecPerMatrixMul[2] = {0, 0};
    double gigaFlops[2] = {0, 0};
    double flopsPerMatrixMul = 2.0 * M * N * K;

    // don't edit it
    const int BLOCK_SIZE_M = 128;
    const int BLOCK_SIZE_K = 8;
    const int BLOCK_SIZE_N = 128;
    const int THREAD_SIZE_X = 8;
    const int THREAD_SIZE_Y = 8;
    const bool ENABLE_DOUBLE_BUFFER = false;
    int k_block = K / BLOCK_SIZE_K;
    int stride = 2;

    // 生成A的数据
    for( int i = 0; i < M * K; i++ ) {
        int row = (i / K);
        int col = (i % K);
        int row_block = row / BLOCK_SIZE_M;
        int col_block = col / BLOCK_SIZE_K;
        if ((row_block * k_block + col_block) % stride == 0) h_A[i] = 1;
        else {
            h_A[i] = 0;
        }
    }

    // 生成B的数据
    for( int i = 0; i < K * N; i++ ) {
        if ( i >= K * N / 2) h_B[i] = 2;
        else {
            h_B[i] = 0;
        }
    }

    checkCudaErrors(cudaMemcpy( d_A, h_A, bytes_A, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy( d_B, h_B, bytes_B, cudaMemcpyHostToDevice));
    
    cudaEvent_t start, stop;
    checkCudaErrors(cudaEventCreate(&start));
    checkCudaErrors(cudaEventCreate(&stop));
    float msecTotal = 0;
    int nIter = 1000;

    checkCudaErrors(cudaMemcpy( d_C, h_C, bytes_C, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaEventRecord(start));
    for (int run = 0 ; run < nIter; run ++ ) {
        dim3 dimBlock(BLOCK_SIZE_N / THREAD_SIZE_X, BLOCK_SIZE_M / THREAD_SIZE_Y);
        dim3 dimGrid(N / BLOCK_SIZE_N, M / BLOCK_SIZE_M);
        Sgemm<BLOCK_SIZE_M, BLOCK_SIZE_K, BLOCK_SIZE_N, THREAD_SIZE_Y, THREAD_SIZE_X, ENABLE_DOUBLE_BUFFER> 
        <<< dimGrid, dimBlock >>>(d_A, d_B, d_C, M, N, K);
    }
    checkCudaErrors(cudaEventRecord(stop));
    checkCudaErrors(cudaEventSynchronize(stop));
    checkCudaErrors(cudaEventElapsedTime(&msecTotal, start, stop));


    checkCudaErrors(cudaMemcpy( h_C, d_C, bytes_C, cudaMemcpyDeviceToHost));

    msecPerMatrixMul[0] = msecTotal / nIter;
    gigaFlops[0] = (flopsPerMatrixMul * 1.0e-9f) / (msecPerMatrixMul[0] / 1000.0f);
    printf( "My gemm Performance= %.2f GFlop/s, Time= %.3f msec, Size= %.0f Ops,\n",
        gigaFlops[0],
        msecPerMatrixMul[0],
        flopsPerMatrixMul);

    // cublas
    
    cublasHandle_t blas_handle;  
    cublasCreate(&blas_handle);
    float alpha = 1.0;
    float beta = 0;
    checkCudaErrors(cudaMemcpy( d_C, h_C, bytes_C, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaEventRecord(start));
    for (int run = 0 ; run < nIter; run ++ ) {
        cublasSgemm (blas_handle, CUBLAS_OP_T, CUBLAS_OP_T, 
            M, N, K, &alpha, 
            d_A, K, d_B, N, &beta, d_C, N
        );
    }
    checkCudaErrors(cudaEventRecord(stop));
    checkCudaErrors(cudaEventSynchronize(stop));
    checkCudaErrors(cudaEventElapsedTime(&msecTotal, start, stop));

    checkCudaErrors(cudaMemcpy( h_C1, d_C, bytes_C, cudaMemcpyDeviceToHost));

    msecPerMatrixMul[1] = msecTotal / nIter;
    gigaFlops[1] = (flopsPerMatrixMul * 1.0e-9f) / (msecPerMatrixMul[1] / 1000.0f);
    printf( "CuBlas Performance= %.2f GFlop/s, Time= %.3f msec, Size= %.0f Ops,\n",
        gigaFlops[1],
        msecPerMatrixMul[1],
        flopsPerMatrixMul);

    cublasDestroy(blas_handle); 

    
    double eps = 1.e-6;  // machine zero
    bool correct = true;
    for (int i = 0; i < M * N; i++) {
        int row = i / N;
        int col = i % N;
        double abs_err = fabs(h_C[i] - h_C1[col * M + row]);
        double dot_length = M;
        double abs_val = fabs(h_C[i]);
        double rel_err = abs_err / abs_val / dot_length;
        if (rel_err > eps) {
            printf("Error! Matrix[%05d]=%.8f, ref=%.8f error term is > %E\n",
                    i, h_C[i], h_C1[col * M + row], eps);
            correct = false;
            break;
        }
    }

    printf("%s\n", correct ? "Result= PASS" : "Result= FAIL");
    printf("ratio= %f\n", gigaFlops[0] / gigaFlops[1]);
    
    // Free Memory
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
    
    free(h_A);
    free(h_B);
    free(h_C);
    free(h_C1);
}
