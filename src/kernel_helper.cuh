/* Copyright 2023 NVIDIA Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#include <cuda_help.h>
#include <utils.h>

namespace legateboost {

template <typename L>
__global__ void __launch_bounds__(THREADS_PER_BLOCK, MIN_CTAS_PER_SM)
  LaunchNKernel(size_t size, L lambda)
{
  for (auto i = blockDim.x * blockIdx.x + threadIdx.x; i < size; i += blockDim.x * gridDim.x) {
    lambda(i);
  }
}

template <int ITEMS_PER_THREAD = 8, typename L>
inline void LaunchN(size_t n, cudaStream_t stream, L lambda)
{
  if (n == 0) { return; }
  const int GRID_SIZE = static_cast<int>((n + ITEMS_PER_THREAD * THREADS_PER_BLOCK - 1) /
                                         (ITEMS_PER_THREAD * THREADS_PER_BLOCK));
  LaunchNKernel<<<GRID_SIZE, THREADS_PER_BLOCK, 0, stream>>>(n, lambda);
}

template <typename T>
void SumAllReduce(legate::TaskContext context, T* x, int count, cudaStream_t stream)
{
  auto domain      = context.get_launch_domain();
  size_t num_ranks = domain.get_volume();
  EXPECT(num_ranks == 1 || context.num_communicators() > 0,
         "Expected a GPU communicator for multi-rank task.");
  if (context.num_communicators() == 0) return;
  auto comm             = context.communicator(0);
  ncclComm_t* nccl_comm = comm.get<ncclComm_t*>();

  if (num_ranks > 1) {
    if (std::is_same<T, float>::value) {
      CHECK_NCCL(ncclAllReduce(x, x, count, ncclFloat, ncclSum, *nccl_comm, stream));
    } else if (std::is_same<T, double>::value) {
      CHECK_NCCL(ncclAllReduce(x, x, count, ncclDouble, ncclSum, *nccl_comm, stream));
    } else {
      EXPECT(false, "Unsupported type for all reduce.");
    }
    CHECK_CUDA_STREAM(stream);
  }
}

}  // namespace legateboost
