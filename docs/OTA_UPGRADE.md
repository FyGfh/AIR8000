# Air8000 OTA 远程升级功能文档

## 概述

本文档描述 VDM Air8000 MCU 的 OTA (Over-The-Air) 远程升级功能。支持两种升级方式：

| 方式 | 网络要求 | 触发方式 | 适用场景 |
|------|----------|----------|----------|
| **MQTT 触发** | Air8000 需要 4G 网络 | 云端推送 | 远程批量升级、4G 信号良好 |
| **串口传输** | Hi3516cv610 需要网络即可 | Hi3516 下载后传输 | 无 4G 信号、内网环境 |

## 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         云端服务器                               │
│                  (固件存储 / MQTT Broker)                        │
└─────────────────────────────────────────────────────────────────┘
                    │                           │
                    │ MQTT                      │ HTTP
                    │ (4G网络)                  │ (以太网)
                    ↓                           ↓
            ┌──────────────┐           ┌──────────────┐
            │   Air8000    │           │ Hi3516cv610  │
            │  (4G模块)    │           │  (主控SoC)   │
            └──────────────┘           └──────────────┘
                    ↑                           │
                    │      USB 虚拟串口          │
                    │      (V1.0 协议)           │
                    └───────────────────────────┘
```

---

## 方式一：MQTT 触发升级

### 适用场景
- Air8000 具备 4G 网络连接
- 需要远程批量推送升级
- 设备分布广泛，无法现场操作

### MQTT 主题

| 主题 | 方向 | 说明 |
|------|------|------|
| `vdm/{IMEI}/ota/cmd` | 订阅 | 接收升级指令 |
| `vdm/{IMEI}/ota/status` | 发布 | 上报设备状态 |

### 升级指令格式

#### 1. 启动升级
```json
{
    "cmd": "upgrade",
    "url": "http://your-server.com/firmware/air8000_v0.4.0.bin",
    "version": "000.400.000"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| cmd | string | 是 | 固定为 "upgrade" |
| url | string | 是 | 固件下载地址，URL 前加 `###` 表示完整 URL |
| version | string | 否 | 目标版本号 |

#### 2. 查询版本
```json
{
    "cmd": "query_version"
}
```

#### 3. 远程重启
```json
{
    "cmd": "reboot"
}
```

### 状态上报格式

Air8000 会定期上报状态，升级过程中也会实时上报：

```json
{
    "imei": "860123456789012",
    "project": "VDM_AIR8000",
    "version": "000.300.000",
    "core_version": "V2012",
    "ota_status": 0,
    "ota_error": 0,
    "rssi": -70,
    "csq": 20,
    "timestamp": 1735520000
}
```

| 字段 | 说明 |
|------|------|
| ota_status | 0=空闲, 1=检查中, 2=下载中, 3=就绪, 4=失败 |
| ota_error | 错误码，见下表 |

### MQTT 配置

在 `main.lua` 中配置 MQTT 服务器：

```lua
mqtt_ota.configure({
    server = "your-mqtt-server.com",  -- MQTT 服务器地址
    port = 1883,                       -- 端口
    username = "",                     -- 用户名（可选）
    password = "",                     -- 密码（可选）
})
mqtt_ota.start()
```

---

## 方式二：串口传输升级

### 适用场景
- Air8000 无 4G 网络或信号差
- Hi3516cv610 通过以太网 (RJ45) 获取固件
- 内网环境部署
- 需要节省 4G 流量

### 协议命令码

| 命令 | 命令码 | 方向 | 说明 |
|------|--------|------|------|
| OTA_UART_START | 0x6010 | Hi3516 → Air8000 | 开始升级 |
| OTA_UART_DATA | 0x6011 | Hi3516 → Air8000 | 固件数据包 |
| OTA_UART_FINISH | 0x6012 | Hi3516 → Air8000 | 升级完成 |
| OTA_UART_ABORT | 0x6013 | Hi3516 → Air8000 | 取消升级 |
| OTA_UART_STATUS | 0x6014 | Air8000 → Hi3516 | 状态通知 (NOTIFY) |

### 完整协议流程

```
Hi3516cv610                              Air8000
    │                                       │
    │  ① 通过以太网下载固件到本地             │
    │                                       │
    ├─── OTA_UART_START (固件大小) ────────→│
    │←─────────── ACK ─────────────────────┤  准备就绪
    │                                       │
    ├─── OTA_UART_DATA (seq=0, data) ─────→│
    │←─────────── ACK ─────────────────────┤
    ├─── OTA_UART_DATA (seq=1, data) ─────→│
    │←─────────── ACK ─────────────────────┤
    │              ...                      │
    │←── NOTIFY OTA_UART_STATUS (进度) ────┤  每 10% 上报
    │              ...                      │
    ├─── OTA_UART_DATA (seq=N, 最后) ─────→│
    │←─────────── ACK ─────────────────────┤
    │                                       │
    ├─── OTA_UART_FINISH ─────────────────→│
    │←─────────── ACK ─────────────────────┤
    │                                       │
    │←── NOTIFY OTA_UART_STATUS (校验中) ──┤
    │←── NOTIFY OTA_UART_STATUS (成功) ────┤
    │                                       │
    │         (Air8000 自动重启)             │
```

### 命令详细格式

#### OTA_UART_START (0x6010)

**请求数据:**
```
[firmware_size: u32 大端序]
```

| 字节 | 内容 | 说明 |
|------|------|------|
| 0-3 | firmware_size | 固件文件大小（字节），大端序 |

**示例:** 固件大小 = 102400 字节 (0x00019000)
```
DATA: 00 01 90 00
```

**响应:** ACK 或 NACK

---

#### OTA_UART_DATA (0x6011)

**请求数据:**
```
[seq: u16 大端序][firmware_data: N bytes]
```

| 字节 | 内容 | 说明 |
|------|------|------|
| 0-1 | seq | 包序号，从 0 开始递增，大端序 |
| 2-N | data | 固件数据，建议每包 512 字节 |

**示例:** 第 3 包 (seq=2)，512 字节数据
```
DATA: 00 02 [512 字节固件数据]
```

**响应:** ACK 或 NACK（携带错误码）

---

#### OTA_UART_FINISH (0x6012)

**请求数据:** 无

**响应:** ACK（开始校验）或 NACK

---

#### OTA_UART_ABORT (0x6013)

**请求数据:** 无

**响应:** ACK

---

#### OTA_UART_STATUS (0x6014) - NOTIFY

**数据格式:**
```
[status: u8][error_code: u8][progress: u8]
```

| 字节 | 内容 | 说明 |
|------|------|------|
| 0 | status | 状态码 |
| 1 | error_code | 错误码 |
| 2 | progress | 进度 0-100% |

**状态码 (status):**

| 值 | 状态 | 说明 |
|----|------|------|
| 0 | IDLE | 空闲 |
| 1 | RECEIVING | 接收中 |
| 2 | VERIFYING | 校验中 |
| 3 | SUCCESS | 成功，即将重启 |
| 4 | FAILED | 失败 |

**错误码 (error_code):**

| 值 | 错误 | 说明 |
|----|------|------|
| 0 | NONE | 无错误 |
| 1 | INIT_FAILED | 初始化失败 |
| 2 | SEQ_ERROR | 序号错误（需重传） |
| 3 | WRITE_FAILED | Flash 写入失败 |
| 4 | VERIFY_FAILED | 校验失败 |
| 5 | TIMEOUT | 超时 |
| 6 | ABORTED | 已取消 |
| 7 | SIZE_MISMATCH | 大小不匹配 |

---

## Hi3516cv610 端实现参考

### C 语言示例

```c
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>

// V1.0 协议帧格式
#define SYNC1 0xAA
#define SYNC2 0x55
#define VERSION 0x10
#define TYPE_REQUEST 0x00
#define TYPE_ACK 0x03
#define TYPE_NACK 0x04

// 命令码
#define CMD_OTA_UART_START  0x6010
#define CMD_OTA_UART_DATA   0x6011
#define CMD_OTA_UART_FINISH 0x6012
#define CMD_OTA_UART_ABORT  0x6013

// CRC-16/MODBUS 计算
uint16_t crc16_modbus(uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            if (crc & 0x0001)
                crc = (crc >> 1) ^ 0xA001;
            else
                crc >>= 1;
        }
    }
    return crc;
}

// 构建请求帧
int build_request(uint8_t *buf, uint8_t seq, uint16_t cmd,
                  uint8_t *data, uint16_t data_len) {
    buf[0] = SYNC1;
    buf[1] = SYNC2;
    buf[2] = VERSION;
    buf[3] = TYPE_REQUEST;
    buf[4] = seq;
    buf[5] = (cmd >> 8) & 0xFF;
    buf[6] = cmd & 0xFF;
    buf[7] = (data_len >> 8) & 0xFF;
    buf[8] = data_len & 0xFF;

    if (data_len > 0) {
        memcpy(buf + 9, data, data_len);
    }

    uint16_t crc = crc16_modbus(buf + 2, 7 + data_len);
    buf[9 + data_len] = (crc >> 8) & 0xFF;
    buf[10 + data_len] = crc & 0xFF;

    return 11 + data_len;
}

// 等待 ACK 响应
int wait_ack(int fd, uint16_t cmd, int timeout_ms) {
    uint8_t buf[64];
    // ... 读取并解析响应
    // 返回 1 = ACK, 0 = NACK/超时
}

// 串口 OTA 升级主函数
int uart_ota_upgrade(const char *uart_dev, const char *firmware_path) {
    // 1. 打开串口
    int fd = open(uart_dev, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        perror("打开串口失败");
        return -1;
    }

    // 配置串口: 115200, 8N1
    // ... 省略串口配置代码

    // 2. 打开固件文件
    FILE *fp = fopen(firmware_path, "rb");
    if (!fp) {
        perror("打开固件失败");
        close(fd);
        return -2;
    }

    fseek(fp, 0, SEEK_END);
    uint32_t firmware_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    printf("固件大小: %u 字节\n", firmware_size);

    // 3. 发送 OTA_UART_START
    uint8_t frame[1024];
    uint8_t start_data[4] = {
        (firmware_size >> 24) & 0xFF,
        (firmware_size >> 16) & 0xFF,
        (firmware_size >> 8) & 0xFF,
        firmware_size & 0xFF
    };

    int frame_len = build_request(frame, 0, CMD_OTA_UART_START,
                                   start_data, 4);
    write(fd, frame, frame_len);

    if (!wait_ack(fd, CMD_OTA_UART_START, 3000)) {
        printf("启动升级失败\n");
        fclose(fp);
        close(fd);
        return -3;
    }

    printf("开始传输固件...\n");

    // 4. 分包发送固件数据
    uint8_t data_buf[514];  // 2 字节 seq + 512 字节数据
    uint16_t seq = 0;
    size_t bytes_read;
    size_t total_sent = 0;

    while ((bytes_read = fread(data_buf + 2, 1, 512, fp)) > 0) {
        // 填充序号 (大端序)
        data_buf[0] = (seq >> 8) & 0xFF;
        data_buf[1] = seq & 0xFF;

        frame_len = build_request(frame, seq & 0xFF, CMD_OTA_UART_DATA,
                                   data_buf, bytes_read + 2);
        write(fd, frame, frame_len);

        if (!wait_ack(fd, CMD_OTA_UART_DATA, 1000)) {
            printf("数据包 %u 发送失败\n", seq);
            // 发送取消命令
            frame_len = build_request(frame, 0, CMD_OTA_UART_ABORT, NULL, 0);
            write(fd, frame, frame_len);
            fclose(fp);
            close(fd);
            return -4;
        }

        seq++;
        total_sent += bytes_read;
        printf("\r进度: %lu / %u (%d%%)", total_sent, firmware_size,
               (int)(total_sent * 100 / firmware_size));
        fflush(stdout);
    }

    printf("\n固件传输完成\n");

    // 5. 发送 OTA_UART_FINISH
    frame_len = build_request(frame, 0, CMD_OTA_UART_FINISH, NULL, 0);
    write(fd, frame, frame_len);

    if (!wait_ack(fd, CMD_OTA_UART_FINISH, 5000)) {
        printf("完成命令失败\n");
        fclose(fp);
        close(fd);
        return -5;
    }

    printf("等待 Air8000 校验并重启...\n");

    // 6. 等待状态通知 (可选)
    // 监听 OTA_UART_STATUS NOTIFY，status=3 表示成功

    fclose(fp);
    close(fd);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        printf("用法: %s <串口设备> <固件文件>\n", argv[0]);
        printf("示例: %s /dev/ttyACM0 air8000_v0.4.0.bin\n", argv[0]);
        return 1;
    }

    return uart_ota_upgrade(argv[1], argv[2]);
}
```

---

## 固件制作

### 使用 Luatools 制作升级包

1. 准备新版本脚本代码，修改 `VERSION` 变量
2. 打开 Luatools，选择 **LuatOS → 固件工具 → 差分包/整包升级包制作**
3. 分别生成新旧版本的量产文件
4. 制作升级包（.bin 文件）
5. 将升级包上传到服务器

### 版本号格式

```lua
PROJECT = "VDM_AIR8000"
VERSION = "000.400.000"  -- 格式: XXX.YYY.ZZZ
```

---

## 注意事项

1. **固件大小限制**: 根据 Air8000 Flash 分区大小，升级包通常不超过 2MB
2. **传输速率**: USB 虚拟串口波特率 115200，每包建议 512 字节
3. **超时处理**: 每包等待 ACK 超时建议 1-3 秒
4. **断点续传**: 当前不支持，失败需重新开始
5. **升级失败**: 收到 NACK 时检查 error_code，根据错误码处理

---

## 相关文件

| 文件 | 说明 |
|------|------|
| `src/ota_update.lua` | OTA 核心模块 |
| `src/mqtt_ota.lua` | MQTT 触发模块 |
| `src/uart_fota.lua` | 串口传输模块 |
| `src/usb_vuart_comm.lua` | V1.0 协议通信模块 |
| `src/main.lua` | 主程序（集成 OTA） |

---

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2025-12-30 | 初始版本，支持 MQTT 和串口传输两种方式 |
