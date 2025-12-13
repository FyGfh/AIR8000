# Hi3516cv610与Air8000 USB虚拟串口通信指南

## 文件说明

- **hi3516cv610_vuart_client.c** - 完整的客户端程序（发送命令+接收响应）
- **hi3516cv610_protocol_parser.c** - 协议解析器（仅接收）

## 编译方法

### 编译客户端程序
```bash
arm-himix410-linux-gcc -o vuart_client hi3516cv610_vuart_client.c
```

### 编译协议解析器
```bash
arm-himix410-linux-gcc -o protocol_parser hi3516cv610_protocol_parser.c
```

## 使用方法

### 1. 测试模式（持续接收）

查看Air8000发送的所有数据（包括测试消息和状态推送）：

```bash
./vuart_client -t
```

**输出示例**：
```
Air8000 USB虚拟串口客户端
设备: /dev/ttyACM0
================================

测试模式：持续接收数据 (按Ctrl+C退出)

🧪 [测试] TEST_MSG_0001
🧪 [测试] TEST_MSG_0002
🔔 [状态推送] CSQ=26, 网络=1, 电量=80%
🧪 [测试] TEST_MSG_0003
```

### 2. 查询传感器数据

```bash
./vuart_client -s
```

**输出示例**：
```
✓ 发送查询命令: 0x11
📊 [传感器数据]
   温度: 25.5°C
   湿度: 60%
   光照: 128
   电量: 80%
```

### 3. 查询电机状态

```bash
./vuart_client -m
```

**输出示例**：
```
✓ 发送查询命令: 0x12
⚙️  [电机状态]
   电机1: 状态=1, 速度=500
   电机2: 状态=0, 速度=0
```

### 4. 查询网络状态

```bash
./vuart_client -n
```

**输出示例**：
```
✓ 发送查询命令: 0x14
📡 [网络状态]
   CSQ: 26
   RSSI: 85
   RSRP: 120
   状态: 1
   IP: 10.21.160.69
```

### 5. 查询所有状态

```bash
./vuart_client -a
```

### 6. 控制电机

**格式**: `./vuart_client -c <电机ID>,<动作>,<速度>`

- **电机ID**: 1 或 2
- **动作**: 0=停止, 1=正转, 2=反转
- **速度**: 0-1000

**示例**：
```bash
# 电机1正转，速度500
./vuart_client -c 1,1,500

# 电机2反转，速度800
./vuart_client -c 2,2,800

# 停止电机1
./vuart_client -c 1,0,0
```

**输出示例**：
```
✓ 发送电机控制: 电机1, 动作=1, 速度=500
✓ [ACK] 命令已确认
```

### 7. 指定不同的串口设备

如果您发现正确的设备是 `/dev/ttyACM1` 或其他：

```bash
./vuart_client -d /dev/ttyACM1 -s
./vuart_client -d /dev/ttyACM2 -m
./vuart_client -d /dev/ttyACM3 -n
```

## 组合使用

可以同时执行多个操作：

```bash
# 查询传感器和电机状态
./vuart_client -s -m

# 控制电机后查询状态
./vuart_client -c 1,1,500 -m
```

## 协议格式

### 发送格式（Hi3516cv610 -> Air8000）

#### 查询命令（无数据）
```
┌─────────┬─────────┬─────────┐
│  CMD    │  0x00   │  0x00   │
│ (1字节) │ (1字节) │ (1字节) │
└─────────┴─────────┴─────────┘
```

**示例（查询传感器）**：
```
0x11 0x00 0x00
```

#### 控制命令（带数据）
```
┌─────────┬─────────┬─────────┬──────────────┐
│  CMD    │ LEN_H   │ LEN_L   │    DATA      │
│ (1字节) │ (1字节) │ (1字节) │  (N字节)     │
└─────────┴─────────┴─────────┴──────────────┘
```

**示例（电机控制）**：
```
0x20 0x00 0x04 0x01 0x01 0x01 0xF4
 │    │    │    │    │    │    └─ 速度低字节 (500 = 0x01F4)
 │    │    │    │    │    └────── 速度高字节
 │    │    │    │    └─────────── 动作 (1=正转)
 │    │    │    └──────────────── 电机ID (1)
 │    │    └───────────────────── 数据长度低字节 (4)
 │    └────────────────────────── 数据长度高字节 (0)
 └─────────────────────────────── 命令 (0x20=电机控制)
```

### 接收格式（Air8000 -> Hi3516cv610）

响应格式相同：
```
┌─────────┬─────────┬─────────┬──────────────┐
│  CMD    │ LEN_H   │ LEN_L   │    DATA      │
└─────────┴─────────┴─────────┴──────────────┘
```

## 命令定义

### 查询命令（Hi3516cv610发送）
| 命令码 | 名称 | 说明 |
|--------|------|------|
| 0x11 | QUERY_SENSOR | 查询传感器状态 |
| 0x12 | QUERY_MOTOR | 查询电机状态 |
| 0x13 | QUERY_ALL | 查询所有状态 |
| 0x14 | QUERY_NETWORK | 查询网络状态 |

### 控制命令
| 命令码 | 名称 | 说明 |
|--------|------|------|
| 0x20 | MOTOR_CTRL | 电机控制 |
| 0x21 | SET_PARAM | 设置参数 |

### 响应命令（Air8000发送）
| 命令码 | 名称 | 说明 |
|--------|------|------|
| 0x01 | RESP_SENSOR | 传感器状态响应 |
| 0x02 | RESP_MOTOR | 电机状态响应 |
| 0x03 | RESP_ALL | 所有状态响应 |
| 0x04 | RESP_NETWORK | 网络状态响应 |
| 0x05 | RESP_ACK | ACK响应 |
| 0x10 | STATUS_PUSH | 定期状态推送（Air8000主动发送） |
| 0xFE | TEST_MSG | 测试消息 |
| 0xFF | RESP_ERROR | 错误响应 |

## 数据格式说明

### 传感器数据 (CMD_RESP_SENSOR, 0x01)
```
字节0-1: 温度 (int16, 实际温度×10)
字节2:   湿度 (uint8, 百分比)
字节3:   光照 (uint8)
字节4:   电量 (uint8, 百分比)
```

### 电机状态 (CMD_RESP_MOTOR, 0x02)
```
字节0:   电机1状态 (uint8)
字节1-2: 电机1速度 (uint16)
字节3:   电机2状态 (uint8)
字节4-5: 电机2速度 (uint16)
```

### 电机控制 (CMD_MOTOR_CTRL, 0x20)
```
字节0:   电机ID (uint8, 1或2)
字节1:   动作 (uint8, 0=停止, 1=正转, 2=反转)
字节2-3: 速度 (uint16, 0-1000)
```

## 集成到您的应用

### C语言集成示例

```c
#include "hi3516cv610_vuart_client.c"

int main() {
    // 打开串口
    uart_fd = open_uart("/dev/ttyACM0");
    if (uart_fd < 0) return 1;

    // 查询传感器
    send_query(CMD_QUERY_SENSOR);
    receive_data(1000);

    // 控制电机
    send_motor_control(1, 1, 500);  // 电机1正转，速度500
    receive_data(1000);

    // 持续接收状态推送
    while (running) {
        receive_data(100);
    }

    close(uart_fd);
    return 0;
}
```

## 调试技巧

### 1. 找到正确的ttyACM设备

```bash
# 快速测试所有设备
for dev in /dev/ttyACM*; do
    echo "Testing $dev..."
    timeout 2 ./vuart_client -d $dev -t | head -5
done
```

### 2. 查看原始数据（含日志）

```bash
cat /dev/ttyACM0
```

### 3. 十六进制查看

```bash
cat /dev/ttyACM0 | hexdump -C
```

### 4. 使用协议解析器（过滤日志）

```bash
./protocol_parser
```

## 故障排查

### 问题1: 设备不存在
```bash
# 检查USB设备
lsusb | grep 19D1

# 检查内核日志
dmesg | grep -i "usb\|cdc\|acm"

# 加载驱动
modprobe cdc_acm
```

### 问题2: 权限不足
```bash
sudo chmod 666 /dev/ttyACM0
```

### 问题3: 收不到响应
- 确认Air8000已烧录新代码
- 确认使用正确的ttyACM设备（可能是ttyACM1-3）
- 增加接收超时时间：修改代码中的 `receive_data(1000)` -> `receive_data(3000)`

## 性能说明

- **波特率**: 115200
- **协议开销**: 每个消息3字节头（命令+长度）
- **最大数据**: 4096字节
- **延迟**: < 10ms（实测）

## 完整示例脚本

```bash
#!/bin/bash
# test_vuart.sh - 完整测试脚本

DEVICE="/dev/ttyACM0"

echo "=== Air8000通信测试 ==="

echo -e "\n1. 查询传感器"
./vuart_client -d $DEVICE -s

echo -e "\n2. 查询电机状态"
./vuart_client -d $DEVICE -m

echo -e "\n3. 控制电机1正转"
./vuart_client -d $DEVICE -c 1,1,500

echo -e "\n4. 查询网络状态"
./vuart_client -d $DEVICE -n

echo -e "\n5. 接收10秒测试消息"
timeout 10 ./vuart_client -d $DEVICE -t

echo -e "\n测试完成"
```

运行：
```bash
chmod +x test_vuart.sh
./test_vuart.sh
```
