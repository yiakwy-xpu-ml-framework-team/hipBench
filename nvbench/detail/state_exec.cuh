/*
 *  Copyright 2021 NVIDIA Corporation 
 *
 *  Licensed under the Apache License, Version 2.0 with the LLVM exception
 *  (the "License"); you may not use this file except in compliance with
 *  the License.
 *
 *  You may obtain a copy of the License at
 *
 *      http://llvm.org/foundation/relicensing/LICENSE.txt
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */


// MIT License
// Modifications Copyright (c) 2024 Advanced Micro Devices, Inc.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#pragma once

#ifndef NVBENCH_STATE_EXEC_GUARD
#error "This is a private implementation header for state.cuh. " \
       "Do not include it directly."
#endif // NVBENCH_STATE_EXEC_GUARD

#include <nvbench/config.cuh>
#include <nvbench/exec_tag.cuh>
#include <nvbench/state.cuh>

#include <nvbench/detail/kernel_launcher_timer_wrapper.cuh>
#include <nvbench/detail/measure_cold.cuh>
#include <nvbench/detail/measure_hot.cuh>

#include <type_traits>

namespace nvbench
{

template <typename ExecTags, typename KernelLauncher>
void state::exec(ExecTags tags, KernelLauncher &&kernel_launcher)
{
  using KL = typename std::remove_reference<KernelLauncher>::type;
  using namespace nvbench::exec_tag::impl;
  static_assert(is_exec_tag_v<ExecTags>,
                "`ExecTags` argument must be a member (or combination of "
                "members) from nvbench::exec_tag.");

  constexpr auto measure_tags  = tags & measure_mask;
  constexpr auto modifier_tags = tags & modifier_mask;

  // "run once" is handled by the cold measurement:
  if (!(modifier_tags & run_once) && this->get_run_once())
  {
    constexpr auto run_once_tags = modifier_tags | cold | run_once;
    this->exec(run_once_tags, std::forward<KernelLauncher>(kernel_launcher));
    return;
  }

  if (!(modifier_tags & no_block) && this->get_disable_blocking_kernel())
  {
    constexpr auto no_block_tags = tags | no_block;
    this->exec(no_block_tags, std::forward<KernelLauncher>(kernel_launcher));
    return;
  }

  // If no measurements selected, pick some defaults based on the modifiers:
  if constexpr (!measure_tags)
  {
    if constexpr (modifier_tags & (timer | sync))
    { // Can't do hot timings with manual timer or sync; whole point is to not
      // sync in between executions.
      this->exec(cold | tags, std::forward<KernelLauncher>(kernel_launcher));
    }
    else
    {
      this->exec(cold | hot | tags, std::forward<KernelLauncher>(kernel_launcher));
    }
    return;
  }

  if (this->is_skipped())
  {
    return;
  }

  // Each measurement is deliberately isolated in constexpr branches to
  // avoid instantiating unused measurements.
  if constexpr (tags & cold)
  {
    constexpr bool use_blocking_kernel = !(tags & no_block);
    if constexpr (tags & timer)
    {
      using measure_t = nvbench::detail::measure_cold<KL, use_blocking_kernel>;
      measure_t measure{*this, kernel_launcher};
      measure();
    }
    else
    { // Need to wrap the kernel launcher with a timer wrapper:
      using wrapper_t = nvbench::detail::kernel_launch_timer_wrapper<KL>;
      wrapper_t wrapper{kernel_launcher};
      using measure_t = nvbench::detail::measure_cold<wrapper_t, use_blocking_kernel>;
      measure_t measure(*this, wrapper);
      measure();
    }
  }

  if constexpr (tags & hot)
  {
    static_assert(!(tags & sync), "Hot measurement doesn't support the `sync` exec_tag.");
    static_assert(!(tags & timer), "Hot measurement doesn't support the `timer` exec_tag.");
    constexpr bool use_blocking_kernel = !(tags & no_block);
    using measure_t                    = nvbench::detail::measure_hot<KL, use_blocking_kernel>;
    measure_t measure{*this, kernel_launcher};
    measure();
  }
}
} // namespace nvbench