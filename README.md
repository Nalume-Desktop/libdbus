# libdbus

面向 Zig 0.17 的独立 libdbus 包装包。提供 Connection、PendingCall、独立驱动接口、Message 消息所有权、本地 Error、消息读取 Iter、消息写入 Writer 和签名校验/遍历。没有接入 zushell，也不依赖其模块。

## 构建与导入

需要 Zig 0.17、pkg-config 和 libdbus 开发包（pkg-config 名称 dbus-1）。

```sh
zig build
zig build test
zig build test-integration # 需要 dbus-run-session，创建独立临时总线
```

构建使用 Zig 内置的 b.addTranslateC 翻译 src/dbus.h，不使用手写 ABI 声明、@cImport 或额外的 translate-c 包。通过系统 pkg-config 获取头文件和动态链接参数。zig build 编译测试，zig build test 编译并执行测试；测试只构造本地消息，不连接 session/system bus。

在另一个项目的 build.zig.zon 声明依赖后：

```zig
const dep = b.dependency("libdbus", .{ .target = target, .optimize = optimize });
module.addImport("libdbus", dep.module("libdbus"));
```

```zig
const dbus = @import("libdbus");
const c = dbus.c; // 原始 dbus_* 函数、结构体和常量。
```

本包没有修改根项目依赖或开发 shell。NixOS 上可通过临时环境提供 dbus.dev 和 pkg-config；无需修改系统配置。已有 Zig 开发 shell 也可在单次构建时将 dbus.dev 的 lib/pkgconfig 加入搜索路径。Nix 的 pkg-config wrapper 可能使用目标专属变量覆盖通用 PKG_CONFIG_PATH；本机 x86_64-linux 验证使用 PKG_CONFIG_PATH_x86_64_unknown_linux_gnu，并保留其原有内容。

## Iter

```zig
const message = c.dbus_message_new(c.DBUS_MESSAGE_TYPE_METHOD_RETURN)
    orelse return error.OutOfMemory;
defer c.dbus_message_unref(message);

// 用 c.dbus_message_iter_init_append / append_basic / open_container 等写入。
var iter = dbus.Iter.init(message);
```

| 操作 | 语义 |
| --- | --- |
| peek() | 查看当前 Type；末尾返回 null，不推进 |
| read(T) | 严格读取一个基本值，成功后推进一项 |
| enter(kind) | 返回子迭代器，同时父迭代器推进一项 |
| skip() | 跳过当前完整值，包括整个容器 |
| expectEnd() | 检查没有多余值，否则返回 TrailingValues |
| elementType() | 查看当前数组的元素种类，不推进；空数组也适用 |
| readBytes() | 读取完整 ay 为借用切片，成功后推进一项 |
| signatureAlloc(allocator) | 复制当前一个值的完整签名，不推进；调用者 allocator.free |

read/enter/readBytes 类型不匹配返回 TypeMismatch；末尾读取返回 EndOfMessage。失败不推进游标。没有额外的 next()，不要在读取后再 skip()，否则会跳过下一个值。

容器种类为 .array、.structure、.dict_entry、.variant。父子游标可以独立前进。未知属性的 Variant 可以整体 skip；无需构建递归 DynamicValue。

read(T) 支持 u8、bool、i16、u16、i32、u32、i64、u64、f64 和以下协议类型：

- String：bytes 为 [:0]const u8，对应 s。
- ObjectPath：bytes 为 [:0]const u8，对应 o。
- Signature：bytes 为 [:0]const u8，对应 g。这是消息中的签名值，与 signatureAlloc 不同。
- UnixFd：fd 为 c_int，对应 h。libdbus 会复制描述符，调用者必须关闭一次；复制包装值不会复制 fd。

不支持 read([]const u8) 的模糊映射：字符串用 read(String)，字节数组用 readBytes。复杂类型由业务显式解析，不执行隐式反射或自动调用 T.decode。

## 结构体自己反序列化

```zig
const Device = struct {
    name: []const u8,
    class: u32,
    powered: bool,

    pub fn decode(iter: *dbus.Iter) !Device {
        var cursor = iter.*;
        var fields = try cursor.enter(.structure);
        const result: Device = .{
            .name = (try fields.read(dbus.String)).bytes,
            .class = try fields.read(u32),
            .powered = try fields.read(bool),
        };
        try fields.expectEnd();
        iter.* = cursor;
        return result;
    }
};

var iter = dbus.Iter.init(message);
const device = try Device.decode(&iter); // 消费一个 (sub)
try iter.expectEnd();
```

本例复制游标，只有成功才提交父游标位置。对于有分配或读取 UnixFd 的解析，复制游标不回滚资源获取：业务解析必须用 errdefer 释放已分配内存/关闭已取得的 fd。

属性字典可以直接遍历：

```zig
var entries = try iter.enter(.array);
while (entries.peek() != null) {
    var entry = try entries.enter(.dict_entry);
    const name = (try entry.read(dbus.String)).bytes;
    var value = try entry.enter(.variant);
    if (std.mem.eql(u8, name, "Powered")) {
        powered = try value.read(bool);
    } else {
        try value.skip();
    }
    try value.expectEnd();
    try entry.expectEnd();
}
```

字段是否必需、重复键策略、未知字段处理由业务决定。进入容器只检查容器种类；如需在空容器上验证完整声明类型，应在 enter 前检查 signatureAlloc 返回的签名。elementType 只返回第一层元素种类。

## 生命周期和边界

- Iter 和子 Iter 都借用消息，不增加引用计数，不需要 deinit。不要直接构造或修改 raw/at_end 字段。
- 消息必须在所有游标和借用值使用期间存活且保持不变；不要同时写入消息或在其他线程修改消息。
- String/ObjectPath/Signature/readBytes 的数据来自消息，不可释放；要跨消息生命周期保留内容，显式复制。
- signatureAlloc 的结果独立拥有内存；用传入的 allocator 释放。libdbus 内部临时签名会由包装层释放。
- UnixFd 是 libdbus 复制出的、设置 CLOEXEC 的独立描述符；它可以超出消息生命周期。复制失败返回 FileDescriptorUnavailable，游标不推进。跳过 fd 不会复制它。
- 本层信任 libdbus 提供的有效消息，负责读取前的类型检查，不重新实现 wire format 或完整协议验证器。

src/tests.zig 包含使用真实 libdbus 消息的结构体和 a{sv} 解析示例、游标失败恢复、空容器、借用数据和资源生命周期测试。

## Writer

Writer 借用可写、未锁定的消息；写入期间必须独占消息。它不持有引用，也不负责发送或释放消息。不要在 Writer 活跃时混用原始 C 写入接口。

	基本类型写入：write(u32/bool/String/ObjectPath/Signature/UnixFd 等)
	字节数组：writeBytes([]const u8)
	打开容器：open(kind, contained_signature, &child)
	关闭子容器：child.close()
	完成根写入：writer.finish()
	清理：writer.deinit() / child.deinit()

完整结构体写入示例：

~~~zig
var writer = dbus.Writer.init(message);
defer writer.deinit();

var fields: dbus.Writer = undefined;
try writer.open(.structure, null, &fields);
defer fields.deinit();
try fields.write(dbus.String{ .bytes = "Adapter" });
try fields.write(@as(u32, 42));
try fields.write(true);
try fields.close();
try writer.finish();
~~~

open 使用调用者提供的子 Writer 存储，保证父子引用稳定。父 Writer 存在打开的子容器时，write/open/close/finish 返回 ActiveChild。打开期间不得复制或移动父子 Writer，也不能把其他活跃 Writer 的存储作为 out 参数。成功 close 后子 Writer 失效；其存储可以重新用于下一次 open。

- array 的签名是一个元素的类型，例如 "s"、"(ub)" 或 "{sv}"；空数组也必须声明。
- variant 的签名必须是一个完整值的类型，例如 "u"、"(sub)" 或 "a{sv}"。
- structure 和 dict_entry 的签名参数为 null；字段类型由写入操作确定。若上层声明了字段类型，Writer 会逐项检查。
- dict_entry 只能位于字典数组中，键和值必须匹配数组声明。
- 数字必须显式使用具体 Zig 类型；不自动推断整数文字的 DBus 位宽。
- 写入字符串时检查 UTF-8、内嵌 NUL、对象路径或签名；类型及输入校验错误在调用 C 写入之前返回。
- 写入字符串会复制内容；写入 UnixFd 会由 libdbus 复制 FD，调用者保留原 FD 的所有权。复制或原生 FD 写入失败返回 FileDescriptorWriteFailed；C API 无法进一步区分 dup 失败与内存不足。

close 会检查 Variant 恰好一个值、结构体非空、字典字段完整，以及声明签名是否匹配。缺失字段导致 IncompleteContainer 时可以继续补写并再次 close。签名限制为 255 字节；Writer 最多允许 64 层活跃容器，其中数组最多 32 层、struct/dict-entry 合计最多 32 层。关闭时还会用 libdbus 校验组成的完整类型签名。

**abandon 不是回滚。** libdbus 明确要求放弃容器后丢弃整条消息。Writer 会递归清理尚未关闭的子容器，并将根 Writer 标记为失败；后续写入或 finish 返回 FailedWriter。不能发送这条消息，也不能通过重新 init 继续使用它。原生写入或关闭失败同样使消息失效。

成功 close/finish 后，deinit 和 abandon 均为无操作，因此可以直接使用 defer 清理。原生 close 即使失败也已使子迭代器失效，包装层不会再次 abandon 它。关闭失败路径遵循 libdbus 的资源规则；正常测试不注入 libdbus 内部内存分配失败。

## Signature 校验与遍历

~~~zig
const signature: dbus.Signature = .{ .bytes = "a{sv}(ub)" };
try signature.validate();       // 允许空签名或多个完整类型
try (dbus.Signature{ .bytes = "a{sv}" }).validateSingle(); // 恰好一个完整类型

var types = try signature.iter();
var array = try types.enter(.array);
var entry = try array.enter(.dict_entry);
// entry.peek() 为 .string；skip 后为 .variant。
~~~

SignatureIter 直接包装 DBusSignatureIter，借用原始签名字节，提供 peek、skip、enter、elementType、signatureAlloc 和 expectEnd。enter 成功后父迭代器前进一个类型，子迭代器独立遍历内部字段。校验使用 libdbus，并额外防止含内嵌 NUL 的切片被 C 接口静默截断。

签名中的 v 不包含 Variant 的内部类型，SignatureIter.enter(.variant) 返回 TypeMismatch；需要从实际消息的 Iter 进入 Variant 才能知道内部类型。

src/writer_tests.zig 覆盖签名校验、类型遍历、写入读回、空容器声明、错误后修正及递归清理。

libdbus 迭代器与 FD 所有权依据：https://dbus.freedesktop.org/doc/api/html/group__DBusMessage.html
签名 API：https://dbus.freedesktop.org/doc/api/html/group__DBusSignature.html

## Message 与 Error

Message 持有一个 DBusMessage 引用。普通 Zig 赋值不会增加引用计数；不要将复制出的两个值都当作所有者释放。

- methodCall(options)：校验 destination/path/interface/member，支持 no_reply、auto_start、interactive_authorization 标志。
- signal(path, interface, member)：创建信号。
- methodReturn(&request)、errorReply(&request, name, text)：请求必须是带有非零 serial 的方法调用。收到的请求由总线携带 serial；普通新建、尚未发送的请求不能直接构造回复。
- ref()：增加引用，返回共享同一底层消息的新所有者。
- copy()：复制消息，serial 重置为零，副本可独立编辑。
- adopt(raw)：接管调用者已有的一个引用；fromBorrowed(raw)：为借用指针新增引用。
- raw()：借用原始指针；release()：转移引用给调用者，并清空当前包装。
- deinit()：释放本包装的引用，对同一包装重复调用安全。释放或转移后不得调用其他访问方法。

~~~zig
var request = try dbus.Message.methodCall(.{
    .destination = "org.example.Service",
    .path = "/org/example",
    .interface = "org.example.Test",
    .member = "Get",
    .auto_start = false,
});
defer request.deinit();

var writer = request.writer();
defer writer.deinit();
try writer.write(dbus.String{ .bytes = "Name" });
try writer.finish();

// 完成消息后可交给 connection.send / startCall / call。
~~~

kind、path、interface、member、sender、destination、signature、serial、replySerial 及标志访问器读取消息头。字符串、Iter 和 Writer 都借用消息，不增加引用。缺失的可选头字段返回 null。

writer() 仍要求调用者独占未锁定的消息，包括通过 ref() 或 raw() 得到的别名。包装层不提供动态借用检查，不能在 Writer 活跃时读取、并发修改或发送消息。需要编辑已接收/已发送的消息时，先 copy()。Message.deinit() 也不会替调用者清理未关闭的 Writer，必须先完成 Writer 的 finish/deinit。

远端错误是一条 Message，kind 为 .error_reply。errorName() 返回错误名称，errorText() 借用消息体中的首个字符串（没有则返回 null），额外字段仍可通过 iter() 读取。它们不会被压成丢失名称和文本的 Zig error。

~~~zig
if (reply.kind() == .error_reply) {
    const name = reply.errorName();
    const text = reply.errorText();
    // name/text 借用 reply；也可通过 reply.iter() 读取完整错误消息体。
    _ = name;
    _ = text;
}
~~~

Error 为原始 C 调用管理 DBusError 存储：

~~~zig
var detail = try dbus.Error.init();
defer detail.deinit();
// 将 detail.out() 传给需要 DBusError* 的 C API。
// out() 要求错误当前未设置；复用前调用 clear()。
if (detail.isSet()) {
    _ = detail.name();
    _ = detail.text();
    _ = detail.hasName("org.freedesktop.DBus.Error.AccessDenied");
}
~~~

DBusError 含有位域，Translate-C 将其表示为 opaque。本包用 error_bridge.c 让 C 编译器处理分配、字段访问及释放，不在 Zig 中手写或猜测结构布局。Error.init() 可能返回 OutOfMemory；name/text 借用 Error，自 clear/deinit 后失效。take() 转移其所有权，原包装之后只能 deinit。Error 不能通过普通赋值复制所有权。

Message.toError() 对非错误消息返回 null；对错误消息调用 libdbus 的 dbus_set_error_from_message，取得独立的 Error 存储。原消息可以随后释放。此转换遵循 libdbus 的文本提取/缺省行为，精确保留所有远端字段应保留原 Message。本地测试覆盖引用、独立副本、原始指针交接、请求校验、回复关联和释放消息后继续读取错误信息，不需要总线。

## Connection 与调用

Connection.connect(io, .session / .system / .starter, &detail) 创建私有连接，并禁止断线退出进程。open(io, address, register_bus, &detail) 可连接指定地址；register_bus=false 用于点对点连接。两者属于原生同步启动过程，可能阻塞，不提供 Io 取消。detail 必须未设置，失败后可读取原生错误名称与文本。

Connection 创建时按值保存 std.Io，借用其后端，不拥有或销毁后端；连接存活期间不得替换它。后端必须活到所有调用、等待和驱动回调结束。call 使用绑定的 Io，不再逐次传入；连接仍不启动后台线程，下面的调用方式要求已有独立驱动持续推进连接：

~~~zig
// connection 已连接，外部 driver 正在独立运行。
var request = try dbus.Message.methodCall(.{
    .destination = "org.freedesktop.DBus",
    .path = "/org/freedesktop/DBus",
    .interface = "org.freedesktop.DBus",
    .member = "ListNames",
});
defer request.deinit();

// 顺序调用：
var reply = try connection.call(&request, .{
    .timeout = .{ .milliseconds = 1000 },
});
defer reply.deinit();

// 或对一个新的、未发送的 request 使用：
// var future = io.async(dbus.Connection.call, .{
//     &connection, &new_request, dbus.Connection.CallOptions{},
// });
// var reply = try future.await(io);
~~~

call 是普通函数：send_with_reply 后注册通知，等待 Io.Event；它不读取 socket、不 flush、不 dispatch。io.async 可能内联执行，不能依靠它启动另一个任务来“以后再推进驱动”。需要保证任务独立推进时使用 io.concurrent（可能返回 ConcurrencyUnavailable），或者由已有 reactor/线程驱动。请求和连接包装的存储须保持有效，直到任务完成或取消并等待结束。

send 只入队并返回 serial；startCall 只入队并返回拥有所有权的 PendingCall。发送会锁定消息，不得保留活跃 Writer；重复发送非零 serial 的消息返回 AlreadySent，需要重新构造或 copy。startCall/call 拒绝非 method_call 或 no_reply 请求。发送失败或本地等待失败不保证远端尚未执行。

PendingCall 是底层单消费者句柄，保留显式 wait(io) 以供自定义等待适配器使用；Connection.call 自动传入连接绑定的 Io。PendingCall 有两种消费方式：wait(io) 等待并取得 Message，或 isCompleted()/takeReply() 非阻塞检查。isCompleted 也会在断线时返回 true；takeReply 在仍等待时返回 null，断线且没有已完成回复时返回 error.Disconnected。wait 在成功、取消和错误时都消费 handle；takeReply 在回复或断线时消费。剩余 handle 的 cancel()/deinit() 取消原生 pending 并释放引用，可以重复 deinit。单个 handle 仅允许一个消费者；运行中的 wait 通过其 Io future 取消，不要从另一个线程同时操作该包装。

超时选项为 .default、.{ .milliseconds = n } 或 .infinite；毫秒数范围为 0..2147483646，原生无限等待保留值 2147483647 会返回 InvalidTimeout。有限超时依赖外部 driver 处理原生 timeout，绝不是 wait 自己轮询时钟。原生超时保留为 org.freedesktop.DBus.Error.NoReply 错误 Message；远端错误也原样返回 Message。Io 取消返回 error.Canceled；本地断线且未收到已完成回复返回 error.Disconnected。取消只停止本地等待，不撤销已经到达远端的方法。等待状态使用线程安全的 C allocator 和引用计数，避免取消与回调竞争导致悬空访问；Io 后端必须活到驱动回调全部结束。

## 独立驱动接口

attachDriver(Driver.Hooks) 接入外部 reactor。Hooks 借用 context，回调保持 libdbus 的 C 调用约定。连接同时只允许一组 hooks；安装失败会撤销本次已安装的注册。detachDriver 会触发 remove 回调；context 必须一直有效到卸载完成。

驱动负责四类工作：

- watch add/remove/toggle：用原生 watch 指针作注册标识，不能只用 fd（多个 watch 可能共享 fd）。Driver.Watch 提供 fd/flags/enabled/handle。禁用 watch 不参与监听；fd 仍归 libdbus 所有，不关闭、不直接读写。把系统 poll 事件转换为 DBUS_WATCH_* 位再传给 handle。
- timeout add/remove/toggle：Driver.Timeout 提供 intervalMs/enabled/handle。启用时按单调时钟安排截止时间，到期调用 handle；toggle 时重新安排。handle 可能同步移除或切换注册，之后不要继续使用失效的指针。
- wakeup 和 dispatch_status：通知 reactor 重新调度；回调里不要等待、dispatch 或重入连接。安装后主动检查一次 dispatchStatus，不能假定注册会补发通知。
- dispatch(budget)：每轮最多处理 budget 条消息；data_remains 时继续调度，need_memory 时稍后重试，不能忙等。收发 fd、超时和 dispatch 是分开的工作，单用 read_write_dispatch 不能代替异步 pending 的 timeout 管理。

回调可能发生在发送/取消线程，而非仅在 driver 线程；适配器必须正确同步注册表和唤醒。remove 返回后原生 watch/timeout 指针失效；跨线程适配器还须保证没有在途操作继续使用该指针，不能仅在加锁复制列表后无保护地使用旧快照。安装/卸载需与连接其他原生操作串行化，只有一个驱动负责 dispatch。

多线程进入任何 libdbus API 前调用 Connection.initThreads()；构造连接时也会幂等调用。close 发起断开，驱动继续分派本地 Disconnected 信号来唤醒已经等待的调用；也可显式取消所有任务。最后依次等待调用结束、停止并 join 驱动、卸载 hooks/deinit 连接，再销毁 Io 后端。不要在等待任务仍引用连接包装时 deinit。高级功能可借用 raw() / c，但不得替换本包安装的 pending 通知或驱动 hooks，也不要吞掉本地 Disconnected 信号。

zig build test-integration 在 dbus-run-session 的临时总线上验证顺序/异步调用、完整远端错误、取消后继续调用、完成早于通知注册、断线、watch/timeout 驱动、安装回滚和卸载。它不使用桌面会话总线，不修改总线配置。原生 libdbus 内部分配失败仍未做故障注入。

### 测试专用驱动

库只提供驱动接入接口；线程模型、事件循环和调度策略由使用方决定。[PollDriver](src/test_support/PollDriver.zig) 是集成测试共用的基础 POSIX poll 驱动，不由库导出，也不自动启动线程。测试不再使用 read_write_dispatch 作为替代路径。

PollDriver 通过 attach/detach 安装和清理 hooks。step(max_wait_ms) 按最近的单调时钟截止时间等待 fd，处理 watch 和 timeout，再进行最多 32 次消息分派；存在待分派消息或唤醒请求时立即继续。注册带有代数标记，避免删除、替换或切换注册后继续使用旧就绪事件。存储容量固定为 16 个 watch、64 个 timeout；容量不足会拒绝注册。它不关闭 libdbus 所有的 fd。

驱动操作和修改注册表的回调必须串行执行；这个测试驱动不支持任意跨线程并发操作连接。它是基础接入示例，不是通用生产 reactor。

[WaitIo](src/test_support/WaitIo.zig) 是配套的最小测试 Io 等待适配器：Event 等待期间调用外部 PollDriver.step，保持所有原生操作在同一线程上。其 async 按 std.Io 允许的语义内联执行，concurrent 不支持；它不是通用 Io 后端。call 的 socket/timeout/dispatch 逻辑仍完全由外部驱动负责，库自身没有加入轮询。

取消、并发等待者收到回复和断线唤醒仍使用真实 std.Io.Threaded。测试通过等待屏障确保驱动分派与等待者清理不重叠；取消时先暂停驱动，等待取消完成后再继续。所有辅助状态保持有效到任务加入结束。驱动等待设有 3 秒测试截止时间，驱动错误直接导致测试失败。

### NetworkManager 实际客户端示例

[只读监视示例](src/examples/README.md) 展示设备和已有 Wi-Fi 接入点查询、属性变化订阅以及服务名称变化处理。运行 zig build run-networkmanager -- --once 查看一次快照，去掉 --once 持续监听；zig build test-networkmanager 运行隔离的模拟服务测试。示例复用基础测试驱动，不向库公共 API 加入驱动或 NetworkManager 专用类型。

## 轻量客户端接口

Remote 借用 Connection、destination、path、interface；初始化只校验，不分配、不访问总线。默认 auto_start=false，可在 target 中显式开启。methodCall(member) 创建填好头部的消息，业务继续用 Writer 编码。call(request, options) 使用连接绑定的 Io，检查回复类型并将远端错误转换为 error.RemoteError。原始 Connection.call 继续返回完整错误 Message。

~~~zig
const device = try dbus.Remote.init(&connection, .{
    .destination = "org.freedesktop.NetworkManager",
    .path = device_path,
    .interface = "org.freedesktop.NetworkManager.Device",
});
var detail: dbus.RemoteError = .{};
defer detail.deinit();
var props = try device.getAllProperties(.{ .remote_error = &detail });
defer props.deinit();
const iface = try props.get(dbus.String, "Interface");
const state = try props.get(u32, "State");
~~~

Properties 拥有回复引用；String、ObjectPath、Signature、字节数组和 value() 的 ValueRef 都借用回复。UnixFd 的读取仍返回必须由调用者关闭的重复描述符。getOptional(T, name) 只把缺失变成 null，类型不匹配仍报错；重复的目标属性报 DuplicateProperty。查找是线性扫描，批量字段可用 iterator() 单次遍历。

getProperty(name, options) 返回拥有单属性回复的 Property，通过 value() 获取已解开协议外层 variant 的值。getScalar(T, name, options) 只允许数字和布尔值；getStringAlloc/getBytesAlloc 显式接收 allocator，调用者 free 返回值。没有隐式递归分配和业务结构体反射。RemoteError.reply 拥有完整错误消息，name()/text() 借用它；需要详细错误时传入 .remote_error，下一次 call 会清理之前的 detail。

Iter.value() 借用当前一个值，不推进游标；nextValue() 返回当前值并推进，结束时返回 null。ValueRef.as(T)、bytes()、enter() 使用独立游标，不修改原视图。unwrapVariant() 只解一层，嵌套 variant 必须显式处理。signatureAlloc 分配完整类型签名，调用者释放；hasSignature 内部使用 libdbus 临时分配，并非零分配。

value.retain() 返回 RetainedValue，以消息引用保留值，不深拷贝。其 view() 仍借用该保留对象；deinit 释放引用。保留小字段也可能保留整条大消息，长期存储少量数据时建议显式复制。PropertyMap.init(value) 可读取其他协议消息中的 a{sv}，包括 PropertiesChanged 的 changed 字典。

## 信号与服务名称生命周期

~~~zig
var subscription = try connection.subscribe(allocator, .{
    .sender = .{ .name = "org.freedesktop.NetworkManager" },
    .path_namespace = "/org/freedesktop/NetworkManager",
    .interface = "org.freedesktop.DBus.Properties",
    .member = "PropertiesChanged",
}, dbus.signalHandler(&monitor, Monitor.changed), .{});
defer subscription.deinit();
// fn changed(self: *Monitor, message: *const dbus.Message) void
~~~

SignalMatch 支持 sender、path 或 path_namespace、interface、member、字符串 arg0。字段经校验并转义，订阅拥有这些字符串的副本。总线匹配与本地校验同时使用，包括命名空间路径边界和发送者；sender.unique 固定 unique name（总线自身可用 org.freedesktop.DBus），sender.name 自动跟踪 well-known name 的当前所有者。每个名称订阅拥有独立 NameWatch，当前没有跨订阅共享注册表或去重缓存。

subscribe 成功表示 AddMatch 已确认。等待期间可能已经运行回调，context 必须事先准备好；失败或取消会移除本地 filter，并在需要时安排 RemoveMatch。回调接收借用 Message，要延后处理须 ref()。普通订阅返回未处理，让其他匹配订阅也能收到消息。

Subscription 和 NameWatch 的初始化等待、生命周期操作和 dispatch 必须在一个串行、可协作推进的执行上下文中运行。它们不提供任意跨线程退订的同步保证。回调可 deinit 自己或其他订阅，正在执行的回调通过原生 filter 引用延迟释放状态；回调不能等待调用、递归 dispatch 或阻塞。绑定 std.Io 不自动满足这些调度条件。

Subscription.deinit 可重复调用，立即停止后续本地投递，使用安装时预先准备的消息和发送资源将 RemoveMatch 入队，不等待确认、不 flush。外部驱动负责发送；立即关闭私有连接时，总线会清理它的全部规则。context 至少存活到退订及当前回调返回；Connection 必须比所有订阅和 NameWatch 活得更久。

NameWatch.init(allocator, connection, name, optional_handler, options) 先订阅 NameOwnerChanged，再读取初始所有者。初始化等待期间发生的变化优先于初始查询结果。handler 可由 NameWatch.handler(context, callback) 构造，收到 Change；初始化可能触发通知。owner() 返回当前 unique name 或 null，generation() 随观察到的变化递增。owner 字符串存于可变内部缓冲区，任何会分派消息的调用前需要自行复制。断线会清空 owner 并通知；不自动重连。

使用一个固定 unique name 发出一组查询，并比较查询前后的 generation，可以识别过期结果；库不自动重发有副作用的方法。Subscription.ownerGeneration() 可查看其内部名称跟踪代数。当前不包含属性缓存、信号队列或 ObjectManager 缓存。

新增测试覆盖值与回复独立保留、空字典类型、重复属性、嵌套 variant、二进制数据、真实总线规则转义、重复规则的平衡清理、回调内退订、旧所有者定向信号、名称查询竞态、取消安装、远端拒绝及 Zig allocator 的逐次故障注入。原生 libdbus 内部分配失败尚未注入；这也不等同于任意线程模型的长期压力验证。

## 标准属性写入与 ObjectManager

Remote.setProperty(name, signature, context, encode, options) 构造标准 Properties.Set 的 ssv 参数。encode(context, writer) 是显式编码函数，必须写入 signature 指定的一个完整值，不能关闭传入的 variant writer；其中打开的子容器仍由编码函数关闭。没有结构体反射或隐式值树分配。编码失败时不发送请求；远端错误由 RemoteError 保留，成功回复必须为空。

~~~zig
fn encodePowered(value: bool, writer: *dbus.Writer) !void {
    try writer.write(value);
}
// 这是显式写操作，只在业务确实要求时调用。
try adapter.setProperty("Powered", "b", true, encodePowered, .{});
~~~

复杂值同样由 Writer 显式构造，例如 signature="as" 时在编码函数里打开 array("s")、逐项写 String、关闭数组。调用一旦发送，取消等待不意味着远端操作没有执行，不应自动重试写操作。

PropertiesChanged.init(message) 校验信号类型、接口、成员及完整 sa{sv}as 签名，返回 interface、changed: PropertyMap 和 invalidated 字符串游标。字符串游标 next() 每次返回一个借用字符串，结束返回 null；复制游标可独立遍历。信号视图不持有消息引用，跨回调保存时须先 Message.ref() 并保持它存活。invalidated 表示值已经失效，需要业务删除旧值或重新查询。

Remote.getManagedObjects(options) 在 target.path 上调用 ObjectManager.GetManagedObjects（接口由助手设置），返回拥有回复引用的 ObjectManager.ManagedObjects。view() 返回 Objects 借用视图；iterator() 逐项返回 path 和 InterfaceMap，后者继续遍历接口名与 PropertyMap。这样可以逐层读取 a{oa{sa{sv}}}，不分配递归对象树。签名校验仍可能使用 libdbus 临时分配。

Objects.getOptional(path) 和 InterfaceMap.getOptional(name) 返回借用视图或 null；重复目标键分别报 DuplicateObject、DuplicateInterface。迭代器保留原始条目，不进行全局去重。view 和迭代结果都不能比 ManagedObjects 活得更久；若需要保留整份快照，保留其拥有者。

ObjectManager.InterfacesAdded.init(message) 校验 oa{sa{sv}} 并返回 path、interfaces；InterfacesRemoved.init(message) 校验 oas 并返回 path、接口名称游标。两者都校验标准信号头并借用源消息。库不自动将这些事件合并到快照，不自动建立 ObjectManager 缓存。

[BlueZ 示例](src/examples/BLUEZ.md) 使用这些协议助手只读查询适配器和已有设备，并订阅属性、对象与服务所有者变化。运行 zig build run-bluez -- --once；zig build test-bluez 使用临时总线测试，完全不修改系统蓝牙状态。

## 独立消费与持续验证

从本仓库根目录运行 bash ci/check.sh。需要 Zig 0.17.0、libdbus 开发头文件与动态库、pkg-config、dbus-run-session、Python 3、Bash 和 timeout。脚本检查 Zig 格式，在 Debug 与 ReleaseSafe 下运行全部测试并编译两个示例；测试只使用隔离 session bus，不访问系统 NetworkManager 或 BlueZ。

[独立消费者](tests/consumer/build.zig) 通过 b.dependency("libdbus", ...) 和 dependency.module("libdbus") 导入库，无须自行添加 C 文件或链接选项。[隔离检查](ci/check-consumer.py) 只复制本包 build.zig.zon 的 .paths 导出文件到临时目录，把消费者放在其旁边并调整相对依赖路径，再使用全新 Zig 缓存运行两个构建模式。检查结束会清理临时文件。它验证本地包依赖和导出完整性，不验证远程发布 URL、下载或归档哈希。

仓库的 .github/workflows/libdbus.yml 在本包或工作流变化时运行相同入口，使用 Ubuntu 24.04 与 Zig 0.17.0。工作流需要提交到托管仓库后才会实际运行；本地通过不代表已在 GitHub runner 验证。

当前实际验证环境是 x86_64 Linux、Zig 0.17.0、libdbus 1.16.2。暂不承诺其他 Zig 版本、非 Linux 系统、交叉编译或静态链接。Ubuntu 工作流使用发行版提供的 libdbus；对应版本的兼容性由该工作流验证。

新增生命周期回归覆盖：Unix FD 经真实私有总线传递，检查 CLOEXEC，释放源消息与两端连接后仍可读；32 轮连接／名称订阅／正常释放或先断开再释放，比较 /proc/self/fd 数量；1024 条各携带 1 KiB 数据的有序信号跨越 dispatch 预算，以及退订后的定向信号不再触发回调。Zig 测试分配器同时检查其管理的内存释放。

这些是有界回归，不等于长期负载测试、原生堆内存泄漏分析或任意跨线程生命周期保证。大对象树规模测试、原生分配失败注入和生产事件循环适配仍待后续验证。

## 非阻塞初始化

Subscription.begin 与 NameWatch.begin 使用和 init 相同的参数，但不等待、不 dispatch。调用方驱动连接并调用 pollReady()：false 表示尚在安装或查询，true 表示初始化完成。错误自动释放句柄，远端错误保存在传入的 RemoteError 中；任意阶段均可 deinit 取消并安排规则清理。pollReady 不推进 socket 或 native timeout，调用者必须持续驱动总线。

NameWatch 先安装名称变更规则，再查询初始 owner，查询期间的名称变化优先于旧回复。Subscription 的 sender.name 包含这个初始化过程。回调可能在 ready 之前触发；context 从 begin 起必须有效，remote_error 须活到初始化完成或句柄释放。ready 只表示初始化完成，连接在线状态须单独检查；初始化完成前 owner()==null 不等于服务不存在。

init 保留原有 Io 等待方式，与 begin/pollReady 共用状态机，仍要求独立推进的驱动。advance(wait) 是两个状态机共享的底层入口，一般调用方使用 init 或 begin/pollReady。初始化推进、dispatch 和释放须串行，不得在回调内递归推进或等待。

## 最小服务端对象

ObjectRegistration.init(allocator, connection, path, methodHandler(context, callback)) 注册精确对象路径，不进行总线往返。注册复制 path，借用 Connection 和回调 context；它们须活到注册及在途回调结束。重复路径返回 ObjectPathInUse。服务名称可以另行通过 startCall 调用总线 RequestName；对象注册不自动申请名称或实现 Properties/Introspection 业务接口。

处理函数接收借用 Message，返回 handled、not_handled 或 need_memory。显式检查接口、方法和参数；未知方法返回 not_handled，交由 libdbus 默认处理。need_memory 仅在没有副作用且可安全重新投递时使用。业务错误可构造 Message.errorReply 并通过 Connection.send 返回。

延迟回复时先 Message.ref() 保留请求，返回 handled 让分派继续，稍后用 Message.methodReturn/errorReply 构造并发送回复，最终释放请求。deinit 停止新请求，支持自身回调内注销并可重复调用；已保留的请求独立存在，不会被注销自动取消。应用负责完成或取消策略，遵守请求的 no-reply 标记，避免重复回复及无限保留。断线后发送返回错误，仍须释放请求消息。

库不创建线程，不向 UI 投递任务，不管理业务模型。跨线程队列、请求 ID、确认界面、结果所有权及重连策略属于应用接入层。
