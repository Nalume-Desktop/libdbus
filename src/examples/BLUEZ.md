# BlueZ 只读监视示例

从本包目录运行：

~~~sh
zig build example-bluez
zig build run-bluez -- --once
zig build run-bluez -- --seconds 10
zig build test-bluez
~~~

构建产物为 zig-out/bin/bluez-monitor。默认 system bus，去掉 --once 持续监听；--seconds N 为主循环软时限，正在进行的查询仍受各自超时约束。--session 只供隔离测试使用。--once 在服务不存在时输出等待提示后退出，查询失败或快照失效最多尝试三次。

[bluez.zig](bluez.zig) 从 / 调用 org.freedesktop.DBus.ObjectManager.GetManagedObjects，输出 Adapter1 和 Device1 的路径、地址、Alias、Powered、Discovering、Paired、Connected、Trusted 和可用的 RSSI。可选属性缺失时保留 unknown 或省略 RSSI，类型错误仍报错；服务返回的文本按字节转义控制字符，不允许设备名称向终端注入转义序列。

只读取 BlueZ 已知的设备，不调用 StartDiscovery、Pair、Connect、Disconnect 或 Properties.Set，不修改 Powered、Trusted 等状态。auto_start=false，不启动未运行的服务。

NameWatch 跟踪 org.bluez。快照固定发送给一个复制后的 unique name；先订阅再取快照，查询期间发生变化会丢弃输出。PropertiesChanged（包括 invalidated 属性）、InterfacesAdded 和 InterfacesRemoved 都通过公共协议视图解析，并只使快照失效；主循环每 250ms 合并刷新，不建立第二套对象缓存。BlueZ 服务消失／重新出现会刷新，系统总线断开则退出，不自动重连。

示例复用 [PollDriver](../test_support/PollDriver.zig) 和配套 WaitIo，仍是固定容量、单线程的示例驱动，不是通用生产 reactor。库只提供外部驱动接入点。方法调用超时 2 秒，辅助驱动等待上限 3 秒。订阅先释放，再卸载驱动和释放连接。

[bluez_tests.zig](bluez_tests.zig) 通过 dbus-run-session 启动隔离服务，不依赖蓝牙硬件。覆盖嵌套对象／接口／属性、未知字段、可选属性缺失、空对象树、错误签名、重复路径／接口、属性变更与失效、设备增删、服务名称消失／重新出现和快照查询竞态。

Properties.Set 测试也只针对这个模拟服务：验证显式 bool 与 as 编码、远端拒绝、非空成功回复拒绝，以及编码失败不发送请求。Labels、Denied、Malformed 是测试协议字段，不是声称真实 BlueZ 提供的属性。
