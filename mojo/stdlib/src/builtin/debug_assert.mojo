# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Implements a debug assert.

These are Mojo built-ins, so you don't need to import them.
"""


from os import abort
from sys import is_amd_gpu, is_gpu, is_nvidia_gpu, llvm_intrinsic
from sys._build import is_debug_build
from sys.ffi import c_char, c_size_t, c_uint, external_call
from sys.intrinsics import block_idx, thread_idx
from sys.param_env import env_get_string

from builtin._location import __call_location, _SourceLocation
from memory import Span, UnsafePointer

from utils.write import (
    _TotalWritableBytes,
    _WriteBufferHeap,
    _WriteBufferStack,
    write_args,
    WritableVariadicPack,
)

alias defined_mode = env_get_string["ASSERT", "safe"]()


@no_inline
fn _assert_enabled[assert_mode: StaticString, cpu_only: Bool]() -> Bool:
    constrained[
        defined_mode == "none"
        or defined_mode == "warn"
        or defined_mode == "safe"
        or defined_mode == "all",
        "-D ASSERT=",
        defined_mode,
        " but must be one of: none, warn, safe, all",
    ]()
    constrained[
        assert_mode == "none" or assert_mode == "safe",
        "assert_mode=",
        assert_mode,
        " but must be one of: none, safe",
    ]()

    @parameter
    if defined_mode == "none" or (is_gpu() and cpu_only):
        return False
    elif defined_mode == "all" or defined_mode == "warn" or is_debug_build():
        return True
    else:
        return defined_mode == assert_mode


@always_inline
fn debug_assert[
    cond: fn () capturing [_] -> Bool,
    assert_mode: StaticString = "none",
    cpu_only: Bool = False,
    *Ts: Writable,
](*messages: *Ts):
    """Asserts that the condition is true.

    Parameters:
        cond: The function to invoke to check if the assertion holds.
        assert_mode: Determines when the assert is turned on.
        cpu_only: If true, only run the assert on CPU.
        Ts: The element types conforming to `Writable` for the message.

    Args:
        messages: Arguments to convert to a `String` message.


    You can pass in multiple args that are `Writable` to generate a formatted
    message, by default this will be a no-op:

    ```mojo
    x = 0
    debug_assert(x > 0, "expected x to be more than 0 but got: ", x)
    ```

    You can change the assertion level for example:

    ```sh
    mojo -D ASSERT=all main.mojo
    ```

    Assertion modes:

    - none: turn off all assertions for performance at the cost of safety.
    - warn: print any errors instead of aborting.
    - safe: standard safety checks that are on even in release builds.
    - all: turn on all assertions.

    You can set the `assert_mode` to `safe` so the assertion runs even in
    release builds:

    ```mojo
    debug_assert[assert_mode="safe"](
        x > 0, "expected x to be more than 0 but got: ", x
    )
    ```

    To ensure that you have no runtime penality from your assertion in release
    builds, make sure there are no side effects in your message and condition.
    Take this example:

    ```mojo
    person = "name: john, age: 50"
    name = "john"
    debug_assert(String("name: ") + name == person, "unexpected name")
    ```

    This will have a runtime penality due to allocating a `String` in the
    condition even in release builds, you must put the condition inside a
    closure so it only runs when the assertion is turned on:

    ```mojo
    fn check_name() capturing -> Bool:
        return String("name: ") + name == person

    debug_assert[check_name]("unexpected name")
    ```

    If you need to allocate, and so don't want the assert to ever run on GPU,
    you can set it to CPU only:

    ```mojo
    debug_assert[check_name, cpu_only=True]("unexpected name")
    ```
    """

    @parameter
    if _assert_enabled[assert_mode, cpu_only]():
        if cond():
            return
        _debug_assert_msg(messages, __call_location())


@always_inline
fn debug_assert[
    assert_mode: StaticString = "none",
    cpu_only: Bool = False,
    *Ts: Writable,
](cond: Bool, *messages: *Ts):
    """Asserts that the condition is true.

    Parameters:
        assert_mode: Determines when the assert is turned on.
        cpu_only: If true, only run the assert on CPU.
        Ts: The element types conforming to `Writable` for the message.

    Args:
        cond: The bool value to assert.
        messages: Arguments to convert to a `String` message.

    You can pass in multiple args that are `Writable` to generate a formatted
    message, by default this will be a no-op:

    ```mojo
    x = 0
    debug_assert(x > 0, "expected x to be more than 0 but got: ", x)
    ```

    You can change the assertion level for example:

    ```sh
    mojo -D ASSERT=all main.mojo
    ```

    Assertion modes:

    - none: turn off all assertions for performance at the cost of safety.
    - warn: print any errors instead of aborting.
    - safe: standard safety checks that are on even in release builds.
    - all: turn on all assertions.

    You can set the `assert_mode` to `safe` so the assertion runs even in
    release builds:

    ```mojo
    debug_assert[assert_mode="safe"](
        x > 0, "expected x to be more than 0 but got: ", x
    )
    ```

    To ensure that you have no runtime penality from your assertion in release
    builds, make sure there are no side effects in your message and condition.
    Take this example:

    ```mojo
    person = "name: john, age: 50"
    name = "john"
    debug_assert(String("name: ") + name == person, "unexpected name")
    ```

    This will have a runtime penality due to allocating a `String` in the
    condition even in release builds, you must put the condition inside a
    closure so it only runs when the assertion is turned on:

    ```mojo
    fn check_name() capturing -> Bool:
        return String("name: ") + name == person

    debug_assert[check_name]("unexpected name")
    ```

    If you need to allocate, and so don't want the assert to ever run on GPU,
    you can set it to CPU only:

    ```mojo
    debug_assert[check_name, cpu_only=True]("unexpected name")
    ```
    """

    @parameter
    if _assert_enabled[assert_mode, cpu_only]():
        if cond:
            return
        _debug_assert_msg(messages, __call_location())


@no_inline
fn _debug_assert_msg[
    origin: ImmutableOrigin, *Ts: Writable
](messages: VariadicPack[origin, Writable, *Ts], loc: _SourceLocation):
    """Aborts with (or prints) the given message and location.

    This function is intentionally marked as no_inline to reduce binary size.

    Note that it's important that this function doesn't get inlined; otherwise,
    an indirect recursion of @always_inline functions is possible (e.g. because
    abort's implementation could use debug_assert)
    """

    @parameter
    if is_gpu():
        print(
            "At ",
            loc,
            ": ",
            _GPUThreadInfo(),
            " Assert ",
            "Warning: " if defined_mode == "warn" else "Error: ",
            WritableVariadicPack(messages),
            sep="",
        )
    else:
        print(
            "At ",
            loc,
            ": ",
            " Assert ",
            "Warning: " if defined_mode == "warn" else "Error: ",
            WritableVariadicPack(messages),
            sep="",
        )

    @parameter
    if defined_mode != "warn":
        abort()


@value
struct _GPUThreadInfo(Writable):
    fn write_to[W: Writer](self, mut writer: W):
        writer.write(
            "block: [",
            block_idx.x,
            ",",
            block_idx.y,
            ",",
            block_idx.z,
            "] thread: [",
            thread_idx.x,
            ",",
            thread_idx.y,
            ",",
            thread_idx.z,
            "]",
        )
