#include "device.h"
#include "tabulate.h"

#define MM 4
#define KK 4
#define TPB 256
#define WARP_SIZE 32
#define FULL_MASK 0xffffffff

template <typename FPTYPE>
__forceinline__ __device__ void locate_xx_se_a(FPTYPE& xx,
                                               int& table_idx,
                                               const FPTYPE& lower,
                                               const FPTYPE& upper,
                                               const FPTYPE& max,
                                               const FPTYPE& stride0,
                                               const FPTYPE& stride1) {
  if (xx < lower) {
    table_idx = 0;
    xx = (FPTYPE)0.;
  } else if (xx < upper) {
    table_idx = (int)((xx - lower) / stride0);
    xx -= (table_idx * stride0 + lower);
  } else if (xx < max) {
    int first_stride = int((upper - lower) / stride0);
    table_idx = first_stride + (int)((xx - upper) / stride1);
    xx -= ((table_idx - first_stride) * stride1 + upper);
  } else {
    table_idx =
        int((upper - lower) / stride0) + (int)((max - upper) / stride1) - 1;
    xx = (FPTYPE)0.;
  }
}

template <typename FPTYPE>
__forceinline__ __device__ void locate_xx_se_t(FPTYPE& xx,
                                               int& table_idx,
                                               const FPTYPE& lower,
                                               const FPTYPE& upper,
                                               const FPTYPE& min,
                                               const FPTYPE& max,
                                               const FPTYPE& stride0,
                                               const FPTYPE& stride1) {
  if (xx < min) {
    table_idx = 0;
    xx = (FPTYPE)0.;
  } else if (xx < lower) {
    table_idx = (int)((xx - min) / stride1);
    xx -= (table_idx * stride1 + min);
  } else if (xx < upper) {
    int first_stride = int((lower - min) / stride1);
    table_idx = first_stride + (int)((xx - lower) / stride0);
    xx -= ((table_idx - first_stride) * stride0 + lower);
  } else if (xx < max) {
    int first_stride =
        int((lower - min) / stride1) + int((upper - lower) / stride0);
    table_idx = first_stride + (int)((xx - upper) / stride1);
    xx -= ((table_idx - first_stride) * stride1 + upper);
  } else {
    table_idx = int((lower - min) / stride1) + int((upper - lower) / stride0) +
                (int)((max - upper) / stride1) - 1;
    xx = (FPTYPE)0.;
  }
}

template <typename FPTYPE>
__forceinline__ __device__ void locate_xx_se_r(FPTYPE& xx,
                                               int& table_idx,
                                               const FPTYPE& lower,
                                               const FPTYPE& upper,
                                               const FPTYPE& max,
                                               const FPTYPE& stride0,
                                               const FPTYPE& stride1) {
  if (xx < lower) {
    table_idx = 0;
    xx = (FPTYPE)0.;
  } else if (xx < upper) {
    table_idx = (int)((xx - lower) / stride0);
    xx -= (table_idx * stride0 + lower);
  } else if (xx < max) {
    int first_stride = int((upper - lower) / stride0);
    table_idx = first_stride + (int)((xx - upper) / stride1);
    xx -= ((table_idx - first_stride) * stride1 + upper);
  } else {
    table_idx =
        int((upper - lower) / stride0) + (int)((max - upper) / stride1) - 1;
    xx = (FPTYPE)0.;
  }
}

template <typename FPTYPE>
__forceinline__ __device__ void load_polynomial_params(
    FPTYPE var[6],
    const FPTYPE* table,
    const int& table_idx,
    const int& idx,
    const int& last_layer_size) {
  var[0] = table[table_idx * last_layer_size * 6 + idx * 6 + 0];
  var[1] = table[table_idx * last_layer_size * 6 + idx * 6 + 1];
  var[2] = table[table_idx * last_layer_size * 6 + idx * 6 + 2];
  var[3] = table[table_idx * last_layer_size * 6 + idx * 6 + 3];
  var[4] = table[table_idx * last_layer_size * 6 + idx * 6 + 4];
  var[5] = table[table_idx * last_layer_size * 6 + idx * 6 + 5];
}

template <typename FPTYPE>
__forceinline__ __device__ FPTYPE dot(FPTYPE ll[4], FPTYPE rr[4]) {
  return ll[0] * rr[0] + ll[1] * rr[1] + ll[2] * rr[2] + ll[3] * rr[3];
}

template <typename FPTYPE>
__forceinline__ __device__ void warp_reduce(FPTYPE& val) {
  for (int offset = 16; offset > 0; offset >>= 1)
    val += __shfl_down_sync(FULL_MASK, val, offset);
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_a_fifth_order_polynomial(
    FPTYPE* out,
    const FPTYPE* table,
    const FPTYPE* em_x,
    const FPTYPE* em,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei,
    const int last_layer_size) {
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // last_layer_size
  FPTYPE ago = __shfl_sync(0xffffffff, em_x[block_idx * nnei + nnei - 1], 0);
  bool unloop = false;
  int breakpoint = nnei - 1;

  FPTYPE sum[MTILE] = {(FPTYPE)0.};
  int mark_table_idx = -1;
  FPTYPE var[6];
  for (int ii = 0; ii < nnei; ii++) {
    FPTYPE xx = em_x[block_idx * nnei + ii];
    if (xx == ago) {
      unloop = true;
      breakpoint = ii;
    }
    int table_idx = 0;
    locate_xx_se_a(xx, table_idx, lower, upper, max, stride0, stride1);
    if (table_idx != mark_table_idx) {
      load_polynomial_params(var, table, table_idx, thread_idx,
                             last_layer_size);
    }
    FPTYPE res =
        var[0] +
        (var[1] + (var[2] + (var[3] + (var[4] + var[5] * xx) * xx) * xx) * xx) *
            xx;

    for (int kk = 0; kk < MTILE; kk++) {
      sum[kk] += (nnei - breakpoint) *
                 em[block_idx * nnei * MTILE + ii * MTILE + kk] * res;
    }
    if (unloop) break;
    mark_table_idx = table_idx;
  }
  for (int ii = 0; ii < MTILE; ii++) {
    out[block_idx * MTILE * last_layer_size + ii * last_layer_size +
        thread_idx] = sum[ii];
  }
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_a_grad_fifth_order_polynomial(
    FPTYPE* dy_dem_x,
    FPTYPE* dy_dem,
    const FPTYPE* table,
    const FPTYPE* em_x,
    const FPTYPE* em,
    const FPTYPE* dy,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei,
    const int last_layer_size) {
  extern __shared__ int _data[];
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // KTILE * WARP_SIZE, usally 128 here~
  int warp_idx = __shfl_sync(0xffffffff, threadIdx.x / WARP_SIZE, 0);
  int lane_idx = threadIdx.x % WARP_SIZE;
  int breakpoint = nnei - 1;
  bool unloop = false;
  FPTYPE* iteratorA = (FPTYPE*)&_data[0];  // dy
  for (int ii = 0; ii < MTILE; ii++) {
    for (int jj = thread_idx; jj < last_layer_size; jj += blockDim.x) {
      iteratorA[ii * last_layer_size + jj] =
          dy[block_idx * MTILE * last_layer_size + ii * last_layer_size + jj];
    }
  }
  __syncthreads();
  FPTYPE ago = __shfl_sync(0xffffffff, em_x[block_idx * nnei + nnei - 1], 0);
  for (int ii = warp_idx; ii < nnei; ii += KTILE) {
    FPTYPE xx = em_x[block_idx * nnei + ii];
    if (ago == xx) {
      unloop = true;
      breakpoint = ii;
    }

    int table_idx = 0;
    FPTYPE reg_em[MTILE] = {em[block_idx * nnei * MTILE + ii * 4 + 0],
                            em[block_idx * nnei * MTILE + ii * 4 + 1],
                            em[block_idx * nnei * MTILE + ii * 4 + 2],
                            em[block_idx * nnei * MTILE + ii * 4 + 3]};
    FPTYPE Csub = (FPTYPE)0.;
    FPTYPE sum[MTILE] = {(FPTYPE)0.};
    locate_xx_se_a(xx, table_idx, lower, upper, max, stride0, stride1);

    FPTYPE var[6];
    for (int jj = lane_idx; jj < last_layer_size; jj += WARP_SIZE) {
      load_polynomial_params(var, table, table_idx, jj, last_layer_size);
      FPTYPE res =
          var[0] +
          (var[1] +
           (var[2] + (var[3] + (var[4] + var[5] * xx) * xx) * xx) * xx) *
              xx;

      for (int kk = 0; kk < MTILE; kk++) {
        sum[kk] +=
            (nnei - breakpoint) * iteratorA[kk * last_layer_size + jj] * res;
      }
      res = reg_em[0] * iteratorA[0 * last_layer_size + jj];
      res += reg_em[1] * iteratorA[1 * last_layer_size + jj];
      res += reg_em[2] * iteratorA[2 * last_layer_size + jj];
      res += reg_em[3] * iteratorA[3 * last_layer_size + jj];
      Csub +=
          (nnei - breakpoint) *
          (var[1] + (2 * var[2] +
                     (3 * var[3] + (4 * var[4] + 5 * var[5] * xx) * xx) * xx) *
                        xx) *
          res;
    }
    __syncwarp();
    for (int kk = 0; kk < MTILE; kk++) {
      warp_reduce(sum[kk]);
    }
    warp_reduce(Csub);
    if (lane_idx == 0) {
      for (int kk = 0; kk < MTILE; kk++) {
        dy_dem[block_idx * nnei * MTILE + ii * 4 + kk] = sum[kk];
      }
      dy_dem_x[block_idx * nnei + ii] = Csub;
    }
    if (unloop) break;
  }
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_a_grad_grad_fifth_order_polynomial(
    FPTYPE* dz_dy,
    const FPTYPE* table,
    const FPTYPE* em_x,
    const FPTYPE* em,
    const FPTYPE* dz_dy_dem_x,
    const FPTYPE* dz_dy_dem,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei,
    const int last_layer_size) {
  extern __shared__ int _data[];
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // last_layer_size
  FPTYPE ago = __shfl_sync(0xffffffff, em_x[block_idx * nnei + nnei - 1], 0);
  bool unloop = false;
  int breakpoint = nnei - 1;
  FPTYPE* iteratorC = (FPTYPE*)&_data[0];
  for (int kk = 0; kk < MTILE; kk++)
    iteratorC[kk * last_layer_size + thread_idx] = (FPTYPE)0.;
  __syncthreads();

  int mark_table_idx = -1;
  FPTYPE var[6];
  for (int ii = 0; ii < nnei; ii++) {
    FPTYPE xx = em_x[block_idx * nnei + ii];
    FPTYPE dz_xx = dz_dy_dem_x[block_idx * nnei + ii];
    if (xx == ago) {
      unloop = true;
      breakpoint = ii;
    }
    int table_idx = 0;
    locate_xx_se_a(xx, table_idx, lower, upper, max, stride0, stride1);
    if (table_idx != mark_table_idx) {
      load_polynomial_params(var, table, table_idx, thread_idx,
                             last_layer_size);
    }

    FPTYPE res =
        var[0] +
        (var[1] + (var[2] + (var[3] + (var[4] + var[5] * xx) * xx) * xx) * xx) *
            xx;
    FPTYPE res_grad =
        var[1] +
        (2 * var[2] + (3 * var[3] + (4 * var[4] + 5 * var[5] * xx) * xx) * xx) *
            xx;

    for (int kk = 0; kk < MTILE; kk++) {
      int em_index = block_idx * nnei * MTILE + ii * MTILE + kk;
      iteratorC[kk * last_layer_size + thread_idx] +=
          (nnei - breakpoint) *
          (em[em_index] * res_grad * dz_xx + dz_dy_dem[em_index] * res);
    }
    mark_table_idx = table_idx;
    if (unloop) break;
  }
  for (int ii = 0; ii < MTILE; ii++) {
    dz_dy[block_idx * MTILE * last_layer_size + ii * last_layer_size +
          thread_idx] = iteratorC[ii * last_layer_size + thread_idx];
  }
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_t_fifth_order_polynomial(
    FPTYPE* out,
    const FPTYPE* table,
    const FPTYPE* em_x,
    const FPTYPE* em,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei_i,
    const int nnei_j,
    const int last_layer_size) {
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // last_layer_size

  FPTYPE sum = (FPTYPE)0.;
  for (int ii = 0; ii < nnei_i; ii++) {
    FPTYPE ago = __shfl_sync(
        0xffffffff,
        em_x[block_idx * nnei_i * nnei_j + ii * nnei_j + nnei_j - 1], 0);
    int breakpoint = nnei_j - 1;
    bool unloop = false;
    FPTYPE var[6];
    int mark_table_idx = -1;
    for (int jj = 0; jj < nnei_j; jj++) {
      FPTYPE xx = em_x[block_idx * nnei_i * nnei_j + ii * nnei_j + jj];
      FPTYPE tmp = xx;
      if (xx == ago) {
        unloop = true;
        breakpoint = jj;
      }
      int table_idx = 0;
      locate_xx_se_t(xx, table_idx, lower, upper, -max, max, stride0, stride1);
      if (table_idx != mark_table_idx) {
        load_polynomial_params(var, table, table_idx, thread_idx,
                               last_layer_size);
      }
      FPTYPE res =
          var[0] +
          (var[1] +
           (var[2] + (var[3] + (var[4] + var[5] * xx) * xx) * xx) * xx) *
              xx;

      sum += (nnei_j - breakpoint) * tmp * res;
      mark_table_idx = table_idx;
      if (unloop) break;
    }
  }
  out[block_idx * last_layer_size + thread_idx] = sum;
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_t_grad_fifth_order_polynomial(
    FPTYPE* dy_dem_x,
    FPTYPE* dy_dem,
    const FPTYPE* table,
    const FPTYPE* em_x,
    const FPTYPE* em,
    const FPTYPE* dy,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei_i,
    const int nnei_j,
    const int last_layer_size) {
  extern __shared__ int _data[];
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // KTILE * WARP_SIZE, usally 128 here~
  int warp_idx = __shfl_sync(0xffffffff, threadIdx.x / WARP_SIZE, 0);
  int lane_idx = threadIdx.x % WARP_SIZE;
  FPTYPE* iteratorA = (FPTYPE*)&_data[0];  // dy
  for (int ii = thread_idx; ii < last_layer_size; ii += blockDim.x) {
    iteratorA[ii] = dy[block_idx * last_layer_size + ii];
  }
  __syncthreads();

  for (int ii = 0; ii < nnei_i; ii++) {
    FPTYPE ago = __shfl_sync(
        0xffffffff,
        em_x[block_idx * nnei_i * nnei_j + ii * nnei_j + nnei_j - 1], 0);
    bool unloop = false;
    for (int jj = warp_idx; jj < nnei_j; jj += KTILE) {
      FPTYPE xx = em_x[block_idx * nnei_i * nnei_j + ii * nnei_j + jj];
      FPTYPE tmp = xx;
      if (ago == xx) {
        unloop = true;
      }
      int table_idx = 0;
      locate_xx_se_t(xx, table_idx, lower, upper, -max, max, stride0, stride1);
      FPTYPE sum = (FPTYPE)0.;
      FPTYPE Csub = (FPTYPE)0.;
      for (int kk = lane_idx; kk < last_layer_size; kk += WARP_SIZE) {
        FPTYPE var[6];
        load_polynomial_params(var, table, table_idx, kk, last_layer_size);
        FPTYPE res =
            var[0] +
            (var[1] +
             (var[2] + (var[3] + (var[4] + var[5] * xx) * xx) * xx) * xx) *
                xx;

        sum += iteratorA[kk] * res;
        Csub +=
            iteratorA[kk] * tmp *
            (var[1] + ((FPTYPE)2. * var[2] +
                       ((FPTYPE)3. * var[3] +
                        ((FPTYPE)4. * var[4] + (FPTYPE)5. * var[5] * xx) * xx) *
                           xx) *
                          xx);
      }
      __syncwarp();
      warp_reduce(sum);
      warp_reduce(Csub);
      if (lane_idx == 0) {
        dy_dem[block_idx * nnei_i * nnei_j + ii * nnei_j + jj] = sum;
        dy_dem_x[block_idx * nnei_i * nnei_j + ii * nnei_j + jj] = Csub;
      }
      if (unloop) break;
    }
  }
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_t_grad_grad_fifth_order_polynomial(
    FPTYPE* dz_dy,
    const FPTYPE* table,
    const FPTYPE* em_x,
    const FPTYPE* em,
    const FPTYPE* dz_dy_dem_x,
    const FPTYPE* dz_dy_dem,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei_i,
    const int nnei_j,
    const int last_layer_size) {
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // last_layer_size

  FPTYPE sum = (FPTYPE)0.;
  for (int ii = 0; ii < nnei_i; ii++) {
    FPTYPE ago = __shfl_sync(
        0xffffffff,
        em_x[block_idx * nnei_i * nnei_j + ii * nnei_j + nnei_j - 1], 0);
    bool unloop = false;
    int mark_table_idx = -1;
    for (int jj = 0; ii < nnei_j; jj++) {
      FPTYPE xx = em_x[block_idx * nnei_i * nnei_j + ii * nnei_j + jj];
      FPTYPE tmp = xx;
      FPTYPE dz_xx =
          dz_dy_dem_x[block_idx * nnei_i * nnei_j + ii * nnei_j + jj];
      FPTYPE dz_em = dz_dy_dem[block_idx * nnei_i * nnei_j + ii * nnei_j + jj];
      FPTYPE var[6];
      if (ago == xx) {
        unloop = true;
      }

      int table_idx = 0;
      locate_xx_se_t(xx, table_idx, lower, upper, -max, max, stride0, stride1);
      if (table_idx != mark_table_idx) {
        load_polynomial_params(var, table, table_idx, thread_idx,
                               last_layer_size);
      }
      FPTYPE res =
          var[0] +
          (var[1] +
           (var[2] + (var[3] + (var[4] + var[5] * xx) * xx) * xx) * xx) *
              xx;
      FPTYPE res_grad =
          var[1] + (2 * var[2] +
                    (3 * var[3] + (4 * var[4] + 5 * var[5] * xx) * xx) * xx) *
                       xx;

      sum += (tmp * res_grad * dz_xx + dz_em * res);
      mark_table_idx = table_idx;
      if (unloop) break;
    }
  }
  dz_dy[block_idx * last_layer_size + thread_idx] = sum;
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_r_fifth_order_polynomial(
    FPTYPE* out,
    const FPTYPE* table,
    const FPTYPE* em,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei,
    const int last_layer_size) {
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // last_layer_size

  int mark_table_idx = -1;
  FPTYPE var[6];
  for (int ii = 0; ii < nnei; ii++) {
    FPTYPE xx = em[block_idx * nnei + ii];
    int table_idx = 0;
    locate_xx_se_r(xx, table_idx, lower, upper, max, stride0, stride1);
    if (table_idx != mark_table_idx) {
      load_polynomial_params(var, table, table_idx, thread_idx,
                             last_layer_size);
    }
    out[block_idx * nnei * last_layer_size + ii * last_layer_size +
        thread_idx] =
        var[0] +
        (var[1] + (var[2] + (var[3] + (var[4] + var[5] * xx) * xx) * xx) * xx) *
            xx;
    mark_table_idx = table_idx;
  }
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_r_grad_fifth_order_polynomial(
    FPTYPE* dy_dem,
    const FPTYPE* table,
    const FPTYPE* em,
    const FPTYPE* dy,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei,
    const int last_layer_size) {
  extern __shared__ int _data[];
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // KTILE * WARP_SIZE, usally 128 here~
  int warp_idx = __shfl_sync(0xffffffff, thread_idx / WARP_SIZE, 0);
  int lane_idx = thread_idx % WARP_SIZE;
  __syncthreads();
  for (int ii = warp_idx; ii < nnei; ii += KTILE) {
    FPTYPE xx = em[block_idx * nnei + ii];

    int table_idx = 0;
    FPTYPE Csub = (FPTYPE)0.;
    locate_xx_se_r(xx, table_idx, lower, upper, max, stride0, stride1);

    FPTYPE var[6];
    for (int jj = lane_idx; jj < last_layer_size; jj += WARP_SIZE) {
      load_polynomial_params(var, table, table_idx, jj, last_layer_size);
      Csub +=
          (var[1] + (2 * var[2] +
                     (3 * var[3] + (4 * var[4] + 5 * var[5] * xx) * xx) * xx) *
                        xx) *
          dy[block_idx * nnei * last_layer_size + ii * last_layer_size + jj];
    }
    __syncwarp();

    warp_reduce(Csub);
    if (lane_idx == 0) {
      dy_dem[block_idx * nnei + ii] = Csub;
    }
  }
}

template <typename FPTYPE, int MTILE, int KTILE>
__global__ void tabulate_fusion_se_r_grad_grad_fifth_order_polynomial(
    FPTYPE* dz_dy,
    const FPTYPE* table,
    const FPTYPE* em,
    const FPTYPE* dz_dy_dem,
    const FPTYPE lower,
    const FPTYPE upper,
    const FPTYPE max,
    const FPTYPE stride0,
    const FPTYPE stride1,
    const int nnei,
    const int last_layer_size) {
  extern __shared__ int _data[];
  const int_64 block_idx = blockIdx.x;  // nloc
  const int thread_idx = threadIdx.x;   // last_layer_size

  int mark_table_idx = -1;
  FPTYPE var[6];
  for (int ii = 0; ii < nnei; ii++) {
    FPTYPE xx = em[block_idx * nnei + ii];
    int table_idx = 0;
    locate_xx_se_r(xx, table_idx, lower, upper, max, stride0, stride1);
    if (table_idx != mark_table_idx) {
      load_polynomial_params(var, table, table_idx, thread_idx,
                             last_layer_size);
    }
    FPTYPE res_grad =
        var[1] +
        (2 * var[2] + (3 * var[3] + (4 * var[4] + 5 * var[5] * xx) * xx) * xx) *
            xx;
    mark_table_idx = table_idx;
    dz_dy[block_idx * nnei * last_layer_size + ii * last_layer_size +
          thread_idx] = dz_dy_dem[block_idx * nnei + ii] * res_grad;
  }
}

namespace deepmd {
template <typename FPTYPE>
void tabulate_fusion_se_a_gpu_cuda(FPTYPE* out,
                                   const FPTYPE* table,
                                   const FPTYPE* table_info,
                                   const FPTYPE* em_x,
                                   const FPTYPE* em,
                                   const int nloc,
                                   const int nnei,
                                   const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  tabulate_fusion_se_a_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, last_layer_size>>>(out, table, em_x, em, table_info[0],
                                  table_info[1], table_info[2], table_info[3],
                                  table_info[4], nnei, last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_a_grad_gpu_cuda(FPTYPE* dy_dem_x,
                                        FPTYPE* dy_dem,
                                        const FPTYPE* table,
                                        const FPTYPE* table_info,
                                        const FPTYPE* em_x,
                                        const FPTYPE* em,
                                        const FPTYPE* dy,
                                        const int nloc,
                                        const int nnei,
                                        const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  DPErrcheck(cudaMemset(dy_dem_x, 0, sizeof(FPTYPE) * nloc * nnei));
  DPErrcheck(cudaMemset(dy_dem, 0, sizeof(FPTYPE) * nloc * nnei * 4));

  tabulate_fusion_se_a_grad_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, KK * WARP_SIZE, sizeof(FPTYPE) * MM * last_layer_size>>>(
          dy_dem_x, dy_dem, table, em_x, em, dy, table_info[0], table_info[1],
          table_info[2], table_info[3], table_info[4], nnei, last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_a_grad_grad_gpu_cuda(FPTYPE* dz_dy,
                                             const FPTYPE* table,
                                             const FPTYPE* table_info,
                                             const FPTYPE* em_x,
                                             const FPTYPE* em,
                                             const FPTYPE* dz_dy_dem_x,
                                             const FPTYPE* dz_dy_dem,
                                             const int nloc,
                                             const int nnei,
                                             const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  DPErrcheck(cudaMemset(dz_dy, 0, sizeof(FPTYPE) * nloc * 4 * last_layer_size));
  tabulate_fusion_se_a_grad_grad_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, last_layer_size, sizeof(FPTYPE) * MM * last_layer_size>>>(
          dz_dy, table, em_x, em, dz_dy_dem_x, dz_dy_dem, table_info[0],
          table_info[1], table_info[2], table_info[3], table_info[4], nnei,
          last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_t_gpu_cuda(FPTYPE* out,
                                   const FPTYPE* table,
                                   const FPTYPE* table_info,
                                   const FPTYPE* em_x,
                                   const FPTYPE* em,
                                   const int nloc,
                                   const int nnei_i,
                                   const int nnei_j,
                                   const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  tabulate_fusion_se_t_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, last_layer_size>>>(
          out, table, em_x, em, table_info[0], table_info[1], table_info[2],
          table_info[3], table_info[4], nnei_i, nnei_j, last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_t_grad_gpu_cuda(FPTYPE* dy_dem_x,
                                        FPTYPE* dy_dem,
                                        const FPTYPE* table,
                                        const FPTYPE* table_info,
                                        const FPTYPE* em_x,
                                        const FPTYPE* em,
                                        const FPTYPE* dy,
                                        const int nloc,
                                        const int nnei_i,
                                        const int nnei_j,
                                        const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  DPErrcheck(cudaMemset(dy_dem_x, 0, sizeof(FPTYPE) * nloc * nnei_i * nnei_j));
  DPErrcheck(cudaMemset(dy_dem, 0, sizeof(FPTYPE) * nloc * nnei_i * nnei_j));

  tabulate_fusion_se_t_grad_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, KK * WARP_SIZE, sizeof(FPTYPE) * last_layer_size>>>(
          dy_dem_x, dy_dem, table, em_x, em, dy, table_info[0], table_info[1],
          table_info[2], table_info[3], table_info[4], nnei_i, nnei_j,
          last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_t_grad_grad_gpu_cuda(FPTYPE* dz_dy,
                                             const FPTYPE* table,
                                             const FPTYPE* table_info,
                                             const FPTYPE* em_x,
                                             const FPTYPE* em,
                                             const FPTYPE* dz_dy_dem_x,
                                             const FPTYPE* dz_dy_dem,
                                             const int nloc,
                                             const int nnei_i,
                                             const int nnei_j,
                                             const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  DPErrcheck(cudaMemset(dz_dy, 0, sizeof(FPTYPE) * nloc * last_layer_size));

  tabulate_fusion_se_t_grad_grad_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, last_layer_size>>>(dz_dy, table, em_x, em, dz_dy_dem_x,
                                  dz_dy_dem, table_info[0], table_info[1],
                                  table_info[2], table_info[3], table_info[4],
                                  nnei_i, nnei_j, last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_r_gpu_cuda(FPTYPE* out,
                                   const FPTYPE* table,
                                   const FPTYPE* table_info,
                                   const FPTYPE* em,
                                   const int nloc,
                                   const int nnei,
                                   const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  tabulate_fusion_se_r_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, last_layer_size>>>(out, table, em, table_info[0], table_info[1],
                                  table_info[2], table_info[3], table_info[4],
                                  nnei, last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_r_grad_gpu_cuda(FPTYPE* dy_dem,
                                        const FPTYPE* table,
                                        const FPTYPE* table_info,
                                        const FPTYPE* em,
                                        const FPTYPE* dy,
                                        const int nloc,
                                        const int nnei,
                                        const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  DPErrcheck(cudaMemset(dy_dem, 0, sizeof(FPTYPE) * nloc * nnei));

  tabulate_fusion_se_r_grad_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, KK * WARP_SIZE, sizeof(FPTYPE) * MM * last_layer_size>>>(
          dy_dem, table, em, dy, table_info[0], table_info[1], table_info[2],
          table_info[3], table_info[4], nnei, last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template <typename FPTYPE>
void tabulate_fusion_se_r_grad_grad_gpu_cuda(FPTYPE* dz_dy,
                                             const FPTYPE* table,
                                             const FPTYPE* table_info,
                                             const FPTYPE* em,
                                             const FPTYPE* dz_dy_dem,
                                             const int nloc,
                                             const int nnei,
                                             const int last_layer_size) {
  if (nloc <= 0) {
    return;
  }
  DPErrcheck(
      cudaMemset(dz_dy, 0, sizeof(FPTYPE) * nloc * nnei * last_layer_size));
  tabulate_fusion_se_r_grad_grad_fifth_order_polynomial<FPTYPE, MM, KK>
      <<<nloc, last_layer_size, sizeof(FPTYPE) * MM * last_layer_size>>>(
          dz_dy, table, em, dz_dy_dem, table_info[0], table_info[1],
          table_info[2], table_info[3], table_info[4], nnei, last_layer_size);
  DPErrcheck(cudaGetLastError());
  DPErrcheck(cudaDeviceSynchronize());
}

template void tabulate_fusion_se_a_gpu_cuda<float>(float* out,
                                                   const float* table,
                                                   const float* table_info,
                                                   const float* em_x,
                                                   const float* em,
                                                   const int nloc,
                                                   const int nnei,
                                                   const int last_layer_size);
template void tabulate_fusion_se_a_gpu_cuda<double>(double* out,
                                                    const double* table,
                                                    const double* table_info,
                                                    const double* em_x,
                                                    const double* em,
                                                    const int nloc,
                                                    const int nnei,
                                                    const int last_layer_size);
template void tabulate_fusion_se_a_grad_gpu_cuda<float>(
    float* dy_dem_x,
    float* dy_dem,
    const float* table,
    const float* table_info,
    const float* em_x,
    const float* em,
    const float* dy,
    const int nloc,
    const int nnei,
    const int last_layer_size);
template void tabulate_fusion_se_a_grad_gpu_cuda<double>(
    double* dy_dem_x,
    double* dy_dem,
    const double* table,
    const double* table_info,
    const double* em_x,
    const double* em,
    const double* dy,
    const int nloc,
    const int nnei,
    const int last_layer_size);
template void tabulate_fusion_se_a_grad_grad_gpu_cuda<float>(
    float* dz_dy,
    const float* table,
    const float* table_info,
    const float* em_x,
    const float* em,
    const float* dz_dy_dem_x,
    const float* dz_dy_dem,
    const int nloc,
    const int nnei,
    const int last_layer_size);
template void tabulate_fusion_se_a_grad_grad_gpu_cuda<double>(
    double* dz_dy,
    const double* table,
    const double* table_info,
    const double* em_x,
    const double* em,
    const double* dz_dy_dem_x,
    const double* dz_dy_dem,
    const int nloc,
    const int nnei,
    const int last_layer_size);

template void tabulate_fusion_se_t_gpu_cuda<float>(float* out,
                                                   const float* table,
                                                   const float* table_info,
                                                   const float* em_x,
                                                   const float* em,
                                                   const int nloc,
                                                   const int nnei_i,
                                                   const int nnei_j,
                                                   const int last_layer_size);
template void tabulate_fusion_se_t_gpu_cuda<double>(double* out,
                                                    const double* table,
                                                    const double* table_info,
                                                    const double* em_x,
                                                    const double* em,
                                                    const int nloc,
                                                    const int nnei_i,
                                                    const int nnei_j,
                                                    const int last_layer_size);
template void tabulate_fusion_se_t_grad_gpu_cuda<float>(
    float* dy_dem_x,
    float* dy_dem,
    const float* table,
    const float* table_info,
    const float* em_x,
    const float* em,
    const float* dy,
    const int nloc,
    const int nnei_i,
    const int nnei_j,
    const int last_layer_size);
template void tabulate_fusion_se_t_grad_gpu_cuda<double>(
    double* dy_dem_x,
    double* dy_dem,
    const double* table,
    const double* table_info,
    const double* em_x,
    const double* em,
    const double* dy,
    const int nloc,
    const int nnei_i,
    const int nnei_j,
    const int last_layer_size);
template void tabulate_fusion_se_t_grad_grad_gpu_cuda<float>(
    float* dz_dy,
    const float* table,
    const float* table_info,
    const float* em_x,
    const float* em,
    const float* dz_dy_dem_x,
    const float* dz_dy_dem,
    const int nloc,
    const int nnei_i,
    const int nnei_j,
    const int last_layer_size);
template void tabulate_fusion_se_t_grad_grad_gpu_cuda<double>(
    double* dz_dy,
    const double* table,
    const double* table_info,
    const double* em_x,
    const double* em,
    const double* dz_dy_dem_x,
    const double* dz_dy_dem,
    const int nloc,
    const int nnei_i,
    const int nnei_j,
    const int last_layer_size);

template void tabulate_fusion_se_r_gpu_cuda<float>(float* out,
                                                   const float* table,
                                                   const float* table_info,
                                                   const float* em,
                                                   const int nloc,
                                                   const int nnei,
                                                   const int last_layer_size);
template void tabulate_fusion_se_r_gpu_cuda<double>(double* out,
                                                    const double* table,
                                                    const double* table_info,
                                                    const double* em,
                                                    const int nloc,
                                                    const int nnei,
                                                    const int last_layer_size);
template void tabulate_fusion_se_r_grad_gpu_cuda<float>(
    float* dy_dem,
    const float* table,
    const float* table_info,
    const float* em,
    const float* dy,
    const int nloc,
    const int nnei,
    const int last_layer_size);
template void tabulate_fusion_se_r_grad_gpu_cuda<double>(
    double* dy_dem,
    const double* table,
    const double* table_info,
    const double* em,
    const double* dy,
    const int nloc,
    const int nnei,
    const int last_layer_size);
template void tabulate_fusion_se_r_grad_grad_gpu_cuda<float>(
    float* dz_dy,
    const float* table,
    const float* table_info,
    const float* em,
    const float* dz_dy_dem,
    const int nloc,
    const int nnei,
    const int last_layer_size);
template void tabulate_fusion_se_r_grad_grad_gpu_cuda<double>(
    double* dz_dy,
    const double* table,
    const double* table_info,
    const double* em,
    const double* dz_dy_dem,
    const int nloc,
    const int nnei,
    const int last_layer_size);

}  // namespace deepmd
