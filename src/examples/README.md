# NetworkManager 只读监视示例

从本包目录运行（Zig 0.17、libdbus-1 开发文件和 pkg-config）：

~~~sh
zig build example-networkmanager
zig build run-networkmanager -- --once
zig build run-networkmanager
zig build run-networkmanager -- --seconds 10
~~~

构建产物是 zig-out/bin/nm-monitor。默认连接 system bus，持续监视；Ctrl-C 退出。
--once 输出一次有效快照后退出，快照失效或查询失败最多重试三次。
--seconds N 在主循环中限制监听时长；正在进行的有界查询和清理仍会完成，因此不是进程的硬截止时间。
--session 仅用于隔离测试服务，不能用它查询通常运行在 system bus 的 NetworkManager。

## 输出

每次输出完整快照，包括 NetworkManager State、设备接口名、类型、状态、对象路径、活动连接路径；无线设备还列出已有接入点的 SSID、信号强度和 Flags/WpaFlags/RsnFlags 原始安全能力位。

SSID 按字节处理。可打印 ASCII 原样输出，其余字节以及引号、反斜线写成十六进制转义；不会假设 SSID 是 UTF-8，也不会把控制字符写到终端。空 SSID 标记为 hidden/unknown。

此程序只调用 GetNameOwner、GetDevices、GetAllAccessPoints 和 Properties.GetAll。AddMatch/RemoveMatch 只管理本程序的信号订阅。不会调用 RequestScan、激活或断开连接、读取连接密钥、修改配置，也不会自动启动 NetworkManager（auto_start=false）。未运行时输出等待提示，服务出现后重新获取快照。

## 事件与生命周期

先安装本地 filter 和匹配规则并等待确认，再查询初始快照。信号回调只增加 revision，不进行同步查询。设备、接入点和属性变化（包括 invalidated 属性）统一触发重新获取快照，250ms 合并变化，避免实现第二套属性缓存。

NameWatch 先订阅名称变化，再查询初始所有者；每轮快照复制当前 unique name，后续查询全部发送给该名称，避免一次查询混用服务重启前后的对象。查询期间收到变化信号就丢弃这一轮输出，再次查询。查询中的对象消失只标记该对象，不中断其余设备。服务名称消失/重新出现触发刷新；system bus 本身断线会报错退出，不自动重连。

这是尽力保持一致的多次查询快照，并不是 NetworkManager 提供的原子事务。信号在快照输出后到达时会触发下一轮刷新；频繁变化可能使 --once 的三次尝试都失效。

示例使用 [PollDriver](../test_support/PollDriver.zig) 的基础单线程驱动，并将配套 WaitIo 绑定到 Connection。它属于测试/示例辅助代码，容量固定，不是库的公共驱动。所有原生操作保持串行，不借助后台线程隐藏驱动过程。每次方法调用设置 2 秒原生超时，等待适配器另有 3 秒测试截止时间。

[networkmanager.zig](networkmanager.zig) 使用公共 Remote、Properties、Subscription 和 NameWatch，无须 C filter 逃生接口。回调只使快照失效，context 一直存活到订阅释放之后。退出时先释放订阅和名称跟踪，再卸载驱动、释放连接；deinit 立即停止本地投递，并将预分配的 RemoveMatch 入队，不等待总线确认。连接关闭也会移除其总线规则。

[nm_protocol.zig](nm_protocol.zig) 保留显式业务 codec 解析设备、接入点及 ao，通用 a{sv}/variant/ay 读取交给 Properties。未知属性可跳过，已知字段类型不符会报错；数据借用 Properties 拥有的回复消息，输出完成后再释放。

## 测试

~~~sh
zig build test test-integration test-networkmanager example-networkmanager
~~~

[test-networkmanager](networkmanager_tests.zig) 在 dbus-run-session 创建的临时总线上运行自己的模拟服务，不需要 NetworkManager 或 Wi-Fi 硬件。覆盖二进制 SSID、未知属性、类型错误、空数组、属性变化及失效属性、快照期间的信号、对象消失、服务名称消失/重新出现和订阅清理。不会重启或改变系统 NetworkManager。

## 接口依据

- [NetworkManager 管理接口](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.html)
- [设备接口](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.Device.html)
- [无线设备接口与 GetAllAccessPoints](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.Device.Wireless.html)
- [接入点属性](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.AccessPoint.html)
