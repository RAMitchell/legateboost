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
#include "legate_library.h"
#include "legateboost.h"
#include "utils.h"
#include "core/comm/coll.h"
#include "build_tree.h"
#include "cuda_help.h"
#include "kernel_helper.cuh"

#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/execution_policy.h>

namespace legateboost {

__global__ static void reduce_base_sums(legate::AccessorRO<double, 2> g,
                                        legate::AccessorRO<double, 2> h,
                                        size_t n_local_samples,
                                        int64_t sample_offset,
                                        legate::Buffer<double, 1> base_sums,
                                        size_t n_outputs)
{
  typedef cub::BlockReduce<double, THREADS_PER_BLOCK> BlockReduce;
  __shared__ typename BlockReduce::TempStorage temp_storage_g;
  __shared__ typename BlockReduce::TempStorage temp_storage_h;

  int32_t output = blockIdx.y;

  int64_t sample_id = threadIdx.x + blockDim.x * blockIdx.x;

  double G = sample_id < n_local_samples ? g[{sample_id + sample_offset, output}] : 0.0;
  double H = sample_id < n_local_samples ? h[{sample_id + sample_offset, output}] : 0.0;

  double blocksumG = BlockReduce(temp_storage_g).Sum(G);
  double blocksumH = BlockReduce(temp_storage_h).Sum(H);

  if (threadIdx.x == 0) {
    atomicAdd(&base_sums[output], blocksumG);
    atomicAdd(&base_sums[output + n_outputs], blocksumH);
  }
}

template <typename TYPE>
__global__ static void fill_histogram(legate::AccessorRO<TYPE, 2> X,
                                      size_t n_local_samples,
                                      size_t n_features,
                                      int64_t sample_offset,
                                      legate::AccessorRO<double, 2> g,
                                      legate::AccessorRO<double, 2> h,
                                      size_t n_outputs,
                                      legate::AccessorRO<TYPE, 2> split_proposal,
                                      legate::Buffer<int32_t, 1> positions,
                                      legate::Buffer<GPair, 4> histogram,
                                      int64_t depth)
{
  // we assume one block per feature*output selection
  // with each block being 1-dimensional
  int64_t feature = blockIdx.x;
  int64_t output  = blockIdx.y;

  for (int64_t sample_id = threadIdx.x; sample_id < n_local_samples; sample_id += blockDim.x) {
    int32_t sample_pos = positions[sample_id];
    if (sample_pos < 0) continue;
    auto x_value = X[{sample_offset + sample_id, feature}];
    bool left    = x_value <= split_proposal[{depth, feature}];

    int position_in_level = sample_pos - ((1 << depth) - 1);

    // this is probably very slow... we should do this in shared memory per block first maybe
    double* addPosition =
      reinterpret_cast<double*>(&histogram[{position_in_level, feature, output, left}]);
    double tmp = g[{sample_offset + sample_id, output}];
    atomicAdd(addPosition, tmp);
    tmp = h[{sample_offset + sample_id, output}];
    atomicAdd(addPosition + 1, tmp);
  }
}

// Key/value pair to simplify reduction
struct GainFeaturePair {
  double gain;
  int feature;

  __device__ void operator=(const GainFeaturePair& other)
  {
    gain    = other.gain;
    feature = other.feature;
  }

  __device__ bool operator==(const GainFeaturePair& other) const
  {
    return gain == other.gain && feature == other.feature;
  }

  __device__ bool operator>(const GainFeaturePair& other) const { return gain > other.gain; }

  __device__ bool operator<(const GainFeaturePair& other) const { return gain < other.gain; }
};

template <typename TYPE>
__global__ static void perform_best_split(legate::Buffer<GPair, 4> histogram,
                                          size_t n_features,
                                          size_t n_outputs,
                                          legate::AccessorRO<TYPE, 2> split_proposal,
                                          double eps,
                                          double learning_rate,
                                          legate::Buffer<double, 2> tree_leaf_value,
                                          legate::Buffer<double, 2> tree_hessian,
                                          legate::Buffer<int32_t, 1> tree_feature,
                                          legate::Buffer<double, 1> tree_split_value,
                                          legate::Buffer<double, 1> tree_gain,
                                          int64_t depth)
{
  // using one block per (level) node to have blockwise reductions
  int node_id = blockIdx.x;

  typedef cub::BlockReduce<GainFeaturePair, THREADS_PER_BLOCK> BlockReduce;
  __shared__ typename BlockReduce::TempStorage temp_storage;

  __shared__ double node_best_gain;
  __shared__ int node_best_feature;

  double thread_best_gain = 0;
  int thread_best_feature = -1;

  for (int feature_id = threadIdx.x; feature_id < n_features; feature_id += blockDim.x) {
    double gain = 0;
    for (int output = 0; output < n_outputs; ++output) {
      auto [G_L, H_L] = histogram[{node_id, feature_id, output, true}];
      auto [G_R, H_R] = histogram[{node_id, feature_id, output, false}];
      auto G          = G_L + G_R;
      auto H          = H_L + H_R;
      if (H_L <= 0.0 || H_R <= 0.0) {
        gain = 0;
        break;
      }
      gain += 0.5 * ((G_L * G_L) / (H_L + eps) + (G_R * G_R) / (H_R + eps) - (G * G) / (H + eps));
    }
    if (gain > thread_best_gain) {
      thread_best_gain    = gain;
      thread_best_feature = feature_id;
    }
  }

  // SYNC BEST GAIN TO FULL BLOCK/NODE
  GainFeaturePair thread_best_pair{thread_best_gain, thread_best_feature};
  GainFeaturePair node_best_pair =
    BlockReduce(temp_storage).Reduce(thread_best_pair, cub::Max(), THREADS_PER_BLOCK);
  if (threadIdx.x == 0) {
    node_best_gain    = node_best_pair.gain;
    node_best_feature = node_best_pair.feature;
  }
  __syncthreads();

  // from here on we need the global node id
  if (node_best_gain > eps) {
    int global_node_id = node_id + ((1 << depth) - 1);
    for (int output = threadIdx.x; output < n_outputs; output += blockDim.x) {
      auto [G_L, H_L] = histogram[{node_id, node_best_feature, output, true}];
      auto [G_R, H_R] = histogram[{node_id, node_best_feature, output, false}];

      int left_child                         = global_node_id * 2 + 1;
      int right_child                        = left_child + 1;
      tree_leaf_value[{left_child, output}]  = -(G_L / (H_L + eps)) * learning_rate;
      tree_leaf_value[{right_child, output}] = -(G_R / (H_R + eps)) * learning_rate;
      tree_hessian[{left_child, output}]     = H_L;
      tree_hessian[{right_child, output}]    = H_R;

      if (output == 0) {
        tree_feature[global_node_id]     = node_best_feature;
        tree_split_value[global_node_id] = split_proposal[{depth, node_best_feature}];
        tree_gain[global_node_id]        = node_best_gain;
      }
    }
  }
}

namespace {

void SumAllReduce(legate::TaskContext& context, double* x, int count, cudaStream_t stream)
{
  if (context.communicators().size() == 0) return;
  auto& comm            = context.communicators().at(0);
  auto domain           = context.get_launch_domain();
  size_t num_ranks      = domain.get_volume();
  ncclComm_t* nccl_comm = comm.get<ncclComm_t*>();

  if (num_ranks > 1) {
    CHECK_NCCL(ncclAllReduce(x, x, count, ncclDouble, ncclSum, *nccl_comm, stream));
    CHECK_CUDA_STREAM(stream);
  }
}

struct Tree {
  Tree(int max_depth, int num_outputs, cudaStream_t stream)
    : num_outputs(num_outputs), max_nodes(1 << (max_depth + 1)), stream(stream)
  {
    leaf_value  = legate::create_buffer<double, 2>({max_nodes, num_outputs});
    feature     = legate::create_buffer<int32_t, 1>({max_nodes});
    split_value = legate::create_buffer<double, 1>({max_nodes});
    gain        = legate::create_buffer<double, 1>({max_nodes});
    hessian     = legate::create_buffer<double, 2>({max_nodes, num_outputs});
  }

  ~Tree()
  {
    leaf_value.destroy();
    feature.destroy();
    split_value.destroy();
    gain.destroy();
    hessian.destroy();
  }

  void InitializeBase(double* base_sums, double learning_rate)
  {
    std::vector<double> base_sums_host(2 * num_outputs);
    CHECK_CUDA(cudaMemcpyAsync(base_sums_host.data(),
                               base_sums,
                               sizeof(double) * num_outputs * 2,
                               cudaMemcpyDeviceToHost,
                               stream));

    auto exec_policy = thrust::cuda::par.on(stream);
    thrust::fill(
      exec_policy, leaf_value.ptr({0, 0}), leaf_value.ptr({0, 0}) + max_nodes * num_outputs, 0.0);
    thrust::fill(exec_policy, feature.ptr({0}), feature.ptr({0}) + max_nodes, -1);
    thrust::fill(
      exec_policy, hessian.ptr({0, 0}), hessian.ptr({0, 0}) + max_nodes * num_outputs, 0.0);

    CHECK_CUDA(cudaStreamSynchronize(stream));

    std::vector<double> leaf_value_init(num_outputs);
    for (auto i = 0; i < num_outputs; ++i) {
      leaf_value_init[i] = (-base_sums_host[i] / base_sums_host[i + num_outputs]) * learning_rate;
    }
    CHECK_CUDA(cudaMemcpyAsync(leaf_value.ptr({0, 0}),
                               leaf_value_init.data(),
                               sizeof(double) * num_outputs,
                               cudaMemcpyHostToDevice,
                               stream));
    CHECK_CUDA(cudaMemcpyAsync(hessian.ptr({0, 0}),
                               base_sums + num_outputs,
                               sizeof(double) * num_outputs,
                               cudaMemcpyDeviceToDevice,
                               stream));

    CHECK_CUDA(cudaStreamSynchronize(stream));
  }

  template <typename T, int DIM>
  void WriteOutput(legate::Store& out, const legate::Buffer<T, DIM>& x)
  {
    // all outputs are 2D
    // for those where the internal buffer is 1D we expect the 2nd extent to be 1
    const legate::Point<DIM> zero   = legate::Point<DIM>::ZEROES();
    const legate::Point<2> zero2    = legate::Point<2>::ZEROES();
    const legate::Rect<2> out_shape = out.shape<2>();
    auto out_acc                    = out.write_accessor<T, 2>();
    EXPECT(DIM == 2 || out_shape.hi[1] == out_shape.lo[1], "Buffer is 1D but store has 2D.");
    EXPECT(out_shape.lo == zero2, "Output store shape should start at zero.");
    EXPECT(out_acc.accessor.is_dense_row_major(out_shape), "Output store is not dense row major.");
    CHECK_CUDA(cudaMemcpyAsync(out_acc.ptr(zero2),
                               x.ptr(zero),
                               out_shape.volume() * sizeof(T),
                               cudaMemcpyDeviceToDevice,
                               stream));
  }

  void WriteTreeOutput(legate::TaskContext& context)
  {
    WriteOutput(context.outputs().at(0), leaf_value);
    WriteOutput(context.outputs().at(1), feature);
    WriteOutput(context.outputs().at(2), split_value);
    WriteOutput(context.outputs().at(3), gain);
    WriteOutput(context.outputs().at(4), hessian);
    CHECK_CUDA_STREAM(stream);
  }

  legate::Buffer<double, 2> leaf_value;
  legate::Buffer<int32_t, 1> feature;
  legate::Buffer<double, 1> split_value;
  legate::Buffer<double, 1> gain;
  legate::Buffer<double, 2> hessian;
  const int num_outputs;
  const int max_nodes;
  cudaStream_t stream;
};

struct build_tree_fn {
  template <legate::Type::Code CODE>
  void operator()(legate::TaskContext& context)
  {
    using T           = legate::legate_type_of<CODE>;
    const auto& X     = context.inputs().at(0);
    auto X_shape      = X.shape<2>();
    auto X_accessor   = X.read_accessor<T, 2>();
    auto num_features = X_shape.hi[1] - X_shape.lo[1] + 1;
    auto num_rows     = X_shape.hi[0] - X_shape.lo[0] + 1;
    const auto& g     = context.inputs().at(1);
    const auto& h     = context.inputs().at(2);
    EXPECT_AXIS_ALIGNED(0, X.shape<2>(), g.shape<2>());
    EXPECT_AXIS_ALIGNED(0, g.shape<2>(), h.shape<2>());
    EXPECT_AXIS_ALIGNED(1, g.shape<2>(), h.shape<2>());
    auto g_shape                = context.inputs().at(1).shape<2>();
    auto num_outputs            = g.shape<2>().hi[1] - g.shape<2>().lo[1] + 1;
    auto g_accessor             = g.read_accessor<double, 2>();
    auto h_accessor             = h.read_accessor<double, 2>();
    const auto& split_proposals = context.inputs().at(3);
    EXPECT_AXIS_ALIGNED(1, split_proposals.shape<2>(), X.shape<2>());
    auto split_proposal_accessor = split_proposals.read_accessor<T, 2>();

    // Scalars
    auto learning_rate = context.scalars().at(0).value<double>();
    auto max_depth     = context.scalars().at(1).value<int>();
    auto random_seed   = context.scalars().at(2).value<uint64_t>();

    auto stream = legate::cuda::StreamPool::get_stream_pool().get_stream();

    Tree tree(max_depth, num_outputs, stream);

    // Initialize the root node
    {
      // base sums contain g-sums first, h sums second [0,...,num_outputs-1, num_outputs, ...,
      // num_outputs*2 -1]
      auto base_sums = legate::create_buffer<double, 1>(num_outputs * 2);
      CHECK_CUDA(cudaMemsetAsync(base_sums.ptr(0), 0, num_outputs * 2 * sizeof(double), stream));

      const size_t blocks = (num_rows + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
      dim3 grid_shape     = dim3(blocks, num_outputs);
      reduce_base_sums<<<grid_shape, THREADS_PER_BLOCK, 0, stream>>>(
        g_accessor, h_accessor, num_rows, X_shape.lo[0], base_sums, num_outputs);
      CHECK_CUDA_STREAM(stream);

      SumAllReduce(context, reinterpret_cast<double*>(base_sums.ptr(0)), num_outputs * 2, stream);

      tree.InitializeBase(base_sums.ptr(0), learning_rate);

      base_sums.destroy();
      CHECK_CUDA_STREAM(stream);
    }

    // Begin building the tree
    auto positions = legate::create_buffer<int32_t, 1>(num_rows);
    CHECK_CUDA(cudaMemsetAsync(positions.ptr(0), 0, num_rows * sizeof(int32_t), stream));

    for (int64_t depth = 0; depth < max_depth; ++depth) {
      int max_nodes = 1 << depth;

      // Dimensions[Node, Feature, Output, L/R]
      auto histogram_buffer =
        legate::create_buffer<GPair, 4>({max_nodes, num_features, num_outputs, 2});
      CHECK_CUDA(cudaMemsetAsync(histogram_buffer.ptr(legate::Point<4>::ZEROES()),
                                 0,
                                 max_nodes * num_features * num_outputs * 2 * sizeof(GPair),
                                 stream));

      dim3 grid_shape = dim3(num_features, num_outputs);
      fill_histogram<<<grid_shape, THREADS_PER_BLOCK, 0, stream>>>(X_accessor,
                                                                   num_rows,
                                                                   num_features,
                                                                   X_shape.lo[0],
                                                                   g_accessor,
                                                                   h_accessor,
                                                                   num_outputs,
                                                                   split_proposal_accessor,
                                                                   positions,
                                                                   histogram_buffer,
                                                                   depth);
      CHECK_CUDA_STREAM(stream);

      SumAllReduce(context,
                   reinterpret_cast<double*>(histogram_buffer.ptr({0, 0, 0, 0})),
                   max_nodes * num_features * num_outputs * 4,
                   stream);

      // Find the best split
      double eps = 1e-5;
      perform_best_split<<<max_nodes, THREADS_PER_BLOCK, 0, stream>>>(histogram_buffer,
                                                                      num_features,
                                                                      num_outputs,
                                                                      split_proposal_accessor,
                                                                      eps,
                                                                      learning_rate,
                                                                      tree.leaf_value,
                                                                      tree.hessian,
                                                                      tree.feature,
                                                                      tree.split_value,
                                                                      tree.gain,
                                                                      depth);
      CHECK_CUDA_STREAM(stream);

      histogram_buffer.destroy();

      // Update the positions
      auto tree_split_value        = tree.split_value;
      auto tree_feature            = tree.feature;
      auto update_positions_lambda = [=] __device__(size_t idx) {
        int32_t pos = positions[idx];
        if (pos < 0 || tree_feature[pos] == -1) {
          positions[idx] = -1;
          return;
        }
        double x_value = X_accessor[{X_shape.lo[0] + (int64_t)idx, tree_feature[pos]}];
        bool left      = x_value <= tree_split_value[pos];
        positions[idx] = left ? 2 * pos + 1 : 2 * pos + 2;
      };

      LaunchN(num_rows, stream, update_positions_lambda);

      CHECK_CUDA_STREAM(stream);
    }

    if (context.get_task_index()[0] == 0) { tree.WriteTreeOutput(context); }
  }
};

}  // namespace

/*static*/ void BuildTreeTask::gpu_variant(legate::TaskContext& context)
{
  const auto& X = context.inputs().at(0);
  type_dispatch_float(X.code(), build_tree_fn(), context);
}

}  // namespace legateboost
