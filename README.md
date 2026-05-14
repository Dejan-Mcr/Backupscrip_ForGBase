# gbpbackup — GBase 备份与归档生命周期管理脚本

> **版本**：v4.1 | **作者**：Dengwenjian@gbase.cn | **更新日期**：2026-05-11
>
> 兼容平台：CentOS 7 / CentOS 8 / Ubuntu 22 etc...

---

## 目录

1. [工具简介](#1-工具简介)
2. [文件说明](#2-文件说明)
3. [快速开始](#3-快速开始)
4. [配置文件详解（.gbpbackup_profile）](#4-配置文件详解gbpbackup_profile)
5. [命令参考](#5-命令参考)
6. [日志系统](#6-日志系统)
7. [监控脚本（monitor_backup.sh）](#7-监控脚本monitor_backupsh)
8. [Crontab 定时任务配置](#8-crontab-定时任务配置)
9. [锁机制说明](#9-锁机制说明)
10. [备份策略说明](#10-备份策略说明)
11. [WAL 归档清理说明](#11-wal-归档清理说明)
12. [故障排查](#12-故障排查)
13. [monitor_backup版本历史](#13-monitor_backup版本历史)
14. [gbpbackup_profile版本历史](#14-gbpbackup_profile版本历史)
15. [gbpbackup版本历史](#15-gbpbackup版本历史)
---

## 1. 工具简介

​`gbpbackup`​ 是基于 `gs_probackup` 封装的 GBase 数据库备份与归档统一管理脚本，提供以下能力：

- **全量 / 增量备份**：支持本地与远程两种模式，增量备份自动校验基础备份有效性，无效时自动降级为全量
- **WAL 归档清理**：基于日历日期的精确保留策略，输出清理前/后/删除文件数统计
- **备份生命周期管理**：按保留数量（`retention_redundancy`​）和时间窗口（`retention_window`）自动过期清理
- **监控集成**：配套 `monitor_backup.sh` 实现对外部应用调用查看备份状态，适用于外部软件调用等备份编排任务
- **统一日志**：所有操作按类型分目录，日志同时输出到终端和文件，支持自动过期清理

---

## 2. 文件说明

```
gbpbackup/
├── gbpbackup                # 主脚本（必须）
├── .gbpbackup_profile       # 配置文件（必须，首次使用前编辑）
├── monitor_backup.sh     # 备份状态监控脚本
├── .gbpbackup.lock          # 运行锁文件（自动创建/删除，勿手动创建）
└── logs/                    # 日志根目录（自动创建）
    ├── init/                # init / set-config 操作日志
    ├── backup/              # backup 操作日志
    ├── archive/             # archive clean 操作日志
    ├── delete/              # delete / checkexpired 操作日志
    ├── validate/            # validate 操作日志
    ├── show/                # show / show-config / show-profile 操作日志
    └── monitor_backup/   # monitor_backup.sh 监控日志
```

> **说明**：`logs/`​ 目录默认在脚本所在目录下生成，可通过 `logs_dir` 参数自定义路径。

---

## 3. 快速开始

### 3.1 前置条

|条件|说明|
| ----------| -------------------------------------------------------------------|
|执行用户|必须以 **非 root** 的数据库安装用户（如 `gbase`）执行|
|环境变量|​`GAUSSHOME`​ 必须已设置（`archive clean`​ 命令依赖此变量定位 `pg_archivecleanup`）|
|依赖工具|​`gs_probackup`​、`gsql`​、`flock`​、`nproc`​（均通过 `GAUSSHOME` 或系统 PATH 提供）|
|Python 3|可选。存在时用于精确解析备份时间；不存在时自动降级为 awk 基础检查|

### 3.2 初次使用步骤

**第一步：编辑配置文件**

```bash
cd /data/backup_gbase/gbpbackup/
vi .gbpbackup_profile
```

至少修改以下必填项（详见 [第 4 章](#4-配置文件详解gbpbackup_profile)）：

```bash
export backups_dir="/data/backup_gbase/backups"
export logs_dir="/data/backup_gbase/logs"
export instance_name="gbase"
export db_port=15400
```

**第二步：初始化备份仓库**

```bash
# 本地模式
./gbpbackup init

# 远程模式（需同时配置远程连接参数）
./gbpbackup init --remote
```

**第三步：执行首次全量备份**

```bash
./gbpbackup backup full
```

**第四步：查看备份结果**

```bash
./gbpbackup show
```

---

## 4. 配置文件详解（.gbpbackup_profile）

配置文件位于脚本同目录下，名为 `.gbpbackup_profile`​，在每次脚本启动时自动 `source`​ 加载。  
配置文件中支持**常量赋值**和  **​`$()`​** ​ **命令替换**两种形式，脚本对加载失败具有容错处理。

### 4.1 参数速查表

|区块|参数名|类型|脚本内置默认值|说明|
| ------| --------| ------------| ----------------| ----------------------------------|
| **[1] 保留策略**|​`retention_redundancy`|整数|​`2`|保留的最少 FULL 备份数量|
||​`retention_window`|整数（天）|​`7`|基于时间的可恢复范围；`0` = 禁用|
| **[2] 目录路径**|​`backups_dir`|路径|​`<脚本目录>/backups`|备份存储根目录 ⭐|
||​`logs_dir`|路径|​`<脚本目录>/logs`|日志存储根目录|
||​`log_retention_time`|整数（天）|​`60`|日志文件自动清理保留天数|
| **[3] 数据库连接**|​`instance_name`|字符串|​`gbase`|gs_probackup 实例名 ⭐|
||​`db_port`|整数|​`15400`|数据库监听端口 ⭐|
| **[4] 备份参数**|​`backup_threads`|整数|​`(CPU核数+1)/2，最低1`|并行备份线程数|
||​`compress_level`|0–9|​`5`|压缩级别；`0`​=不压缩，`9`=最高压缩|
| **[5] WAL 归档**|​`retention_days`|整数（天）|​`7`|WAL 归档保留天数|
||​`archive_dir`|路径|​`<backups_dir>/wal/<instance_name>`|WAL 归档存储路径|
| **[6] 备机备份**|​`is_standby_backup`|​`true`​/`false`|​`false`|允许从备机执行备份|
| **[7] 远程备份**|​`dbauser`|字符串|空|远程数据库认证用户|
||​`dbpasswd`|字符串|空|远程数据库密码|
||​`remote_host`|IP 地址|空|远程数据库主机 IP|
||​`remote_user`|字符串|​`gbase`|远程 SSH 登录用户|
||​`remote_port`|整数|​`22`|远程 SSH 端口|

> ⭐ 标注为常用必改项。

### 4.2 配置文件示例（本地模式）

```bash
# [1] 保留策略
export retention_redundancy=3   # 至少保留 3 个全量备份
export retention_window=7       # 可恢复最近 7 天内任意时间点

# [2] 目录路径
export backups_dir="/data/backup_gbase/backups"
export logs_dir="/data/backup_gbase/logs"
export log_retention_time=60    # 日志保留 60 天

# [3] 数据库连接
export instance_name="gbase"
export db_port=15400

# [4] 备份参数
export backup_threads="$(( ( $(nproc 2>/dev/null || echo 2) + 1 ) / 2 ))"
export compress_level=5

# [5] WAL 归档
export retention_days=7
export archive_dir="${backups_dir}/wal/${instance_name}"

# [6] 备机备份
export is_standby_backup=false
```

### 4.3 配置文件示例（远程模式附加）

```bash
# [7] 远程备份（使用 --remote 参数时必填）
export dbauser="gsadmin"
export dbpasswd="your_password_here"
export remote_host="192.168.123.120"
export remote_user="gbase"
export remote_port=22
```

### 4.4 优先级规则

配置文件中的值优先于脚本内置默认值。若某个变量在配置文件中未设置或配置文件不存在，脚本自动使用内置默认值兜底，**脚本不会因配置文件缺失而直接退出**。

---

## 5. 命令参考

### 5.1 命令总览

```
gbpbackup init [--remote]
gbpbackup set-config
gbpbackup backup full|increment [--remote]
gbpbackup archive clean
gbpbackup delete -i <backupid>
gbpbackup checkexpired
gbpbackup validate
gbpbackup show
gbpbackup show-config
gbpbackup show-profile
gbpbackup --help
```

---

### 5.2 `init` — 初始化备份仓库

```bash
./gbpbackup init           # 本地模式初始化
./gbpbackup init --remote  # 远程模式初始化
```

**执行流程：**

1. 验证远程参数（`--remote` 模式）
2. 连接数据库，获取 `data_directory`​（`init` 阶段跳过主备角色检查）
3. 执行 `gs_probackup init -B <backups_dir>`
4. 执行 `gs_probackup add-instance` 注册实例
5. 执行 `gs_probackup set-config` 写入保留策略和压缩参数
6. 日志写入：`logs/init/init_<local|remote>_YYYYMMDD.log`

> **注意**：`init` 仅需执行一次。重复执行会尝试重新初始化仓库，可能引发错误。

---

### 5.3 `set-config` — 更新备份配置

```bash
./gbpbackup set-config
```

在不重新初始化仓库的前提下，将 `.gbpbackup_profile`​ 中的策略参数（`retention_redundancy`​、`retention_window`​、`compress_level`​）同步写入 `gs_probackup` 实例配置。修改配置文件参数后执行此命令使其生效。

日志写入：`logs/init/init_set-config_YYYYMMDD.log`

---

### 5.4 `backup` — 执行备份

```bash
./gbpbackup backup full              # 全量备份（本地）
./gbpbackup backup full --remote     # 全量备份（远程）
./gbpbackup backup increment         # 增量备份（本地）
./gbpbackup backup increment --remote  # 增量备份（远程）
```

**增量备份自动降级逻辑：**

执行 `backup increment`​ 时，脚本会检查最近 7 天内是否存在状态为 `OK` 的 FULL 备份：

- ✅ **存在有效基础备份** → 执行 ptrack 增量备份
- ❌ **不存在或已过期** → 自动降级为全量备份，并输出警告日志

> 依赖 Python 3 精确解析备份时间戳；Python 3 不可用时降级为 awk 基础检查（仅判断 OK 状态存在，不验证时间）。

**备份完成后自动执行：**

1. ​`validate` — 验证备份完整性
2. ​`checkexpired` — 清理过期备份

以上两步复用备份日志文件，不产生额外日志文件。

**锁机制：**  备份期间持有 `.gbpbackup.lock` 文件锁，防止并发执行。

日志写入：`logs/backup/backup_<full|increment>[_remote]_YYYYMMDD.log`

---

### 5.5 `archive clean` — 清理过期 WAL 归档

```bash
./gbpbackup archive clean
```

**依赖：**  `$GAUSSHOME`​ 环境变量必须已设置（用于定位 `$GAUSSHOME/bin/pg_archivecleanup`）。

**清理策略（自然日期保留）：**

```
截止日期 = 今天 - retention_days
```

1. 在 `archive_dir`​ 中查找修改时间落在截止日期当天（00:00–23:59）的 `.backup` 文件，选取最新的一个作为基准
2. 若截止日期当天无 `.backup`​ 文件，向前搜索最近一个早于截止日期的 `.backup` 文件
3. 调用 `pg_archivecleanup <archive_dir> <baseline_WAL>` 删除早于基准 WAL 的所有归档文件

**清理统计输出示例：**

```
Archive cleanup statistics:
  Files before cleanup : 312
  Files after cleanup  : 48
  Files removed        : 264
```

日志写入：`logs/archive/archive_clean_YYYYMMDD.log`

---

### 5.6 `delete` — 删除指定备份

```bash
./gbpbackup delete -i <backupid>

# 示例
./gbpbackup delete -i TE8UX3
```

通过备份 ID 删除单个备份。备份 ID 可通过 `./gbpbackup show` 查看。

日志写入：`logs/delete/delete_manual_YYYYMMDD.log`

---

### 5.7 `checkexpired` — 清理过期备份

```bash
./gbpbackup checkexpired
```

根据 `retention_redundancy`​（最少保留全备数量）和 `retention_window`（恢复窗口天数）自动删除不满足策略的过期备份。备份命令执行后会自动调用此命令，也可独立执行。

日志写入：`logs/delete/delete_expired_YYYYMMDD.log`

---

### 5.8 `validate` — 验证备份完整性

```bash
./gbpbackup validate
```

对所有备份文件进行完整性校验。备份命令执行后会自动调用此命令，也可独立执行。

日志写入：`logs/validate/validate_YYYYMMDD.log`

---

### 5.9 `show`​ / `show-config`​ / `show-profile` — 查看信息

```bash
./gbpbackup show           # 查看备份列表（包含 ID、类型、状态、大小、时间等）
./gbpbackup show-config    # 查看 gs_probackup 实例当前配置
./gbpbackup show-profile   # 查看 .gbpbackup_profile 文件内容（当前生效配置）
./gbpbackup --help         # 查看帮助及当前生效参数值
```

日志均写入 `logs/show/` 目录。

---

## 6. 日志系统

### 6.1 日志格式

所有日志采用统一格式，同时输出到终端和日志文件：

```
[YYYY-MM-DD HH:MM:SS] [SCRIPT] [LEVEL] : <message>
```

|级别|含义|
| ------| --------------------------------------|
|​`INFO`|常规执行信息|
|​`WARN`|警告（如增量降级为全量、归档无匹配）|
|​`ERROR`|错误（输出到 stderr）|
|​`OK`|操作成功完成|

### 6.2 日志文件命名规则

|命令|日志路径|
| ------| ------------|
|​`init`|​`logs/init/init_local_YYYYMMDD.log`​ 或 `init_remote_YYYYMMDD.log`|
|​`set-config`|​`logs/init/init_set-config_YYYYMMDD.log`|
|​`backup full`|​`logs/backup/backup_full_YYYYMMDD.log`|
|​`backup full --remote`|​`logs/backup/backup_full_remote_YYYYMMDD.log`|
|​`backup increment`|​`logs/backup/backup_increment_YYYYMMDD.log`|
|​`backup increment --remote`|​`logs/backup/backup_increment_remote_YYYYMMDD.log`|
|​`archive clean`|​`logs/archive/archive_clean_YYYYMMDD.log`|
|​`delete -i <id>`|​`logs/delete/delete_manual_YYYYMMDD.log`|
|​`checkexpired`|​`logs/delete/delete_expired_YYYYMMDD.log`|
|​`validate`|​`logs/validate/validate_YYYYMMDD.log`|
|​`show`|​`logs/show/show_backups_YYYYMMDD.log`|
|​`show-config`|​`logs/show/show_config_YYYYMMDD.log`|
|​`show-profile`|​`logs/show/show_profile_YYYYMMDD.log`|
|​`monitor_backup.sh`|​`logs/monitor_backup/monitor_YYYYMMDD.log`|

> 同一天多次执行同类命令，日志**追加**到同一文件（不覆盖）。

### 6.3 日志自动清理

每次命令执行时，脚本自动清理 `logs/`​ 目录下超过 `log_retention_time`​（默认 60 天）的 `.log` 文件及空目录。

---

## 7. 监控脚本（monitor_backup.sh）

### 7.1 用途

用于在维护窗口或自动化流程中**阻塞等待**当前 `backup full/increment` 命令执行完毕，适合"先等备份完成再执行后续操作"的场景。

> **注意**：监控脚本仅监控 `backup`​ 命令的锁文件。`archive clean`​、`show`​、`validate` 等命令不使用锁，无需监控等待。

### 7.2 用法

```bash
# 监控同目录下的 gbpbackup 锁（脚本自动定位自身路径）
./monitor_backup.sh
```

### 7.3 工作逻辑

```
启动
  │
  ├── 锁文件不存在? ──→ 直接输出 OK，退出码 0
  │
  └── 锁文件存在，进入循环（每 5 秒检测一次）
        │
        ├── 能获取锁（flock -n）且 gs_probackup 进程不存在
        │     └──→ 输出 OK，退出码 0（备份正常完成）
        │
        ├── 不能获取锁 + gs_probackup 进程存在
        │     └──→ 输出等待信息，继续等待
        │
        └── 不能获取锁 + gs_probackup 进程不存在
              └──→ 输出 FAILED，退出码 1（死锁/僵尸锁，需人工介入）
```

### 7.4 退出码含义

|退出码|含义|建议操作|
| --------| ------------------------------------| -----------------------|
|​`0`|备份已完成或未在运行|可继续后续操作|
|​`1`|检测到死锁（锁被占用但无对应进程）|检查进程，手动删除 `.gbpbackup.lock`|
|​`130`|用户按 Ctrl+C 中断|—|

### 7.5 日志

监控日志独立存放：`logs/monitor_backup/monitor_YYYYMMDD.log`，同样采用追加方式。

---

## 8. Crontab 定时任务配置

### 8.1 编辑 Crontab

以数据库安装用户（如 `gbase`）执行：

```bash
crontab -e
```

### 8.2 推荐配置方案

```bash
# ============================================================
# gbpbackup 定时备份任务配置
# 执行用户: gbase
# ============================================================

# 每周日 01:00 执行全量备份
0 1 * * 0 source /home/gbase/.bashrc; /data/backup_gbase/gbpbackup/gbpbackup backup full >>/dev/null 2>&1 &

# 每周一至周六 01:00 执行增量备份（若无有效全量备份，自动降级为全量）
0 1 * * 1-6 source /home/gbase/.bashrc; /data/backup_gbase/gbpbackup/gbpbackup backup increment >>/dev/null 2>&1 &

# 每天 02:00 清理过期 WAL 归档
0 2 * * * source /home/gbase/.bashrc; /data/backup_gbase/gbpbackup/gbpbackup archive clean >>/dev/null 2>&1 &

# 可选：每周一 03:00 单独检查并清理过期备份
# 0 3 * * 1 source /home/gbase/.bashrc; /data/backup_gbase/gbpbackup/gbpbackup checkexpired >>/dev/null 2>&1 &
```

### 8.3 关键配置说明

|配置项|说明|是否必须|
| --------| -------------------------------------------------------------------| ----------|
|​`source /home/gbase/.bashrc`|加载用户环境变量，确保 `GAUSSHOME`​、`PATH`​、`LD_LIBRARY_PATH`​ 等正确设置，`archive clean` 命令对此有强依赖|**必须**|
|​`>>/dev/null 2>&1`|抑制 crontab 邮件通知，日志由 gbpbackup 自行管理|建议保留|
|​`&`|后台执行，避免 crontab 等待进程结束（尤其全量备份耗时较长）|**必须**|

> ​**​`source`​**​ **路径说明**：若 `GAUSSHOME`​ 等变量定义在其他文件中（如 `/etc/profile.d/gausshome.sh`​），相应替换 source 路径。可通过 `env | grep GAUSSHOME` 确认当前会话中该变量是否已生效。

---

## 9. 锁机制说明

​`gbpbackup backup`​ 命令在执行期间通过 `flock`​ 对 `.gbpbackup.lock` 文件加互斥锁：

- 锁文件路径：`<脚本目录>/.gbpbackup.lock`
- 锁类型：非阻塞独占锁（`flock -n`）
- 持锁期间：从开始备份到脚本进程退出（含 validate、checkexpired 阶段）
- 脚本退出时（正常或异常）

**只有** **​`backup`​**​ **命令使用锁**，`archive clean`​、`validate`​、`checkexpired`​、`show` 等命令不使用锁，可与备份并发执行（但不建议）。

---

## 10. 备份策略说明

### 10.1 保留策略参数

|参数|作用|
| ------| --------------------------------------------------------------------------------------|
|​`retention_redundancy`|至少保留的 FULL 备份数量。即使这些备份已超出时间窗口，也不会被删除，直到数量超过此值|
|​`retention_window`|可恢复的时间范围（天）。该窗口内的 FULL 备份及其依赖的增量备份均被保留|

两个参数同时生效，较宽松的一方胜出（即满足其中任一条件的备份都会被保留）。

### 10.2 压缩参数

|​`compress_level`|算法|说明|
| --------| ------| ----------------------------------------|
|​`0`|none|不压缩，速度最快，占用空间最大|
|​`1–9`|zlib|压缩级别越高，压缩率越高，CPU 消耗越大|
|默认值|​`5`|平衡压缩率与性能|

### 10.3 增量备份有效性检查

执行 `backup increment`​ 时，脚本检查最近 7 天内是否存在 `status=OK` 的 FULL 备份。判断逻辑：

```
最新 FULL 备份结束时间距今 ≤ 7 天  →  执行增量
最新 FULL 备份结束时间距今 > 7 天  →  自动降级为全量，并输出 [WARN]
无任何 OK 状态的 FULL 备份        →  自动降级为全量，并输出 [WARN]
```

---

## 11. WAL 归档清理说明

​`archive clean` 基于自然日历日期计算截止点，避免因执行时刻不同导致每次清理粒度不一致。

**计算流程：**

```
截止日期 = 今天 - retention_days（例：今天 2026-05-01，保留 7 天 → 截止日期 2026-04-24）

第一优先：查找修改时间为 2026-04-24 的最新 .backup 文件
第二优先：若当天无 .backup 文件，向前搜索最近一个早于 2026-04-24 的 .backup 文件

使用找到的 .backup 文件对应的 WAL 段名（前 24 位十六进制字符）作为基准，
调用 pg_archivecleanup 删除所有早于该基准的 WAL 文件。
```

**日志输出示例：**

```
[INFO] Current time       : 2026-05-01 02:00:03
[INFO] Retention policy   : 7 calendar days
[INFO] Cutoff date        : 2026-04-24 (00:00:00 - 23:59:59)
[INFO] Preserve from      : 2026-04-25 00:00:00 onwards
[INFO] Selected baseline  : 000000010000000100000041.00000028.backup
[INFO] Baseline mtime     : 2026-04-24 14:35:22
[INFO] Baseline WAL       : 000000010000000100000041
[INFO] Action             : Remove all WAL segments OLDER than 000000010000000100000041
[INFO] Archive cleanup statistics:
[INFO]   Files before cleanup : 312
[INFO]   Files after cleanup  : 48
[INFO]   Files removed        : 264
[OK]   Archive cleanup completed
```

---

## 12. 故障排查

### 问题 1：执行备份时提示 `gbpbackup backup already running`

**原因**：`.gbpbackup.lock` 被占用，另一个备份进程正在运行，或上次备份异常退出遗留了死锁。

**排查步骤：**

```bash
# 1. 检查是否有正在运行的备份进程
ps -ef | grep gs_probackup | grep -v grep

# 2. 若无进程但锁文件存在，说明是死锁，手动删除锁文件
ls -l .gbpbackup.lock
rm .gbpbackup.lock

# 3. 使用监控脚本辅助判断
./monitor_backup.sh
```

---

### 问题 2：监控脚本输出 `FAILED (Stale lock detected)`

**原因**：`.gbpbackup.lock`​ 存在，但无对应 `gs_probackup` 进程，属于死锁状态。

**解决：**

```bash
rm /data/backup_gbase/gbpbackup/.gbpbackup.lock
```

删除后可重新执行备份。

---

### 问题 3：`archive clean`​ 提示 `GAUSSHOME is not set`

**原因**：当前 shell 环境中 `GAUSSHOME`​ 未设置，导致无法定位 `pg_archivecleanup`。

**解决：**

```bash
# 确认当前会话是否有 GAUSSHOME
echo $GAUSSHOME

# 若为空，手动加载环境或在命令前 source .bashrc
source /home/gbase/.bashrc
./gbpbackup archive clean

# Crontab 中确保已添加 source 语句（见第 8 章）
```

---

### 问题 4：crontab 执行失败但手动执行正常

**原因**：crontab 运行环境不继承用户登录 shell 的环境变量（`GAUSSHOME`​、`PATH` 等）。

**解决：**

确认 crontab 任务行包含：

```bash
source /home/gbase/.bashrc;
```

验证方法：

```bash
# 模拟 crontab 环境执行
env -i HOME=/home/gbase bash -c 'source /home/gbase/.bashrc; echo $GAUSSHOME'
```

---

### 问题 5：增量备份自动降级为全量

**原因**：最近 7 天内无 `status=OK` 的 FULL 备份（可能因为 7 天未执行全量，或上次全量备份状态为非 OK）。

**排查：**

```bash
./gbpbackup show          # 查看备份列表，检查 FULL 备份状态和时间
./gbpbackup validate      # 验证备份完整性
```

---

### 问题 6：备份失败，提示 `DB connection failed`

**原因**：gsql 无法连接数据库，可能是端口、用户或数据库状态问题。

**排查：**

```bash
# 检查数据库是否运行
gs_ctl status -D $GAUSSDATA

# 手动测试连接
gsql -d postgres -p ${db_port} -At -c "select 1;"

# 检查 db_port 配置是否正确
./gbpbackup show-profile
```

---
## 13. monitor_backup脚本版本历史

```
# v2.4 (2026-05-11):
#   - Lock file open mode: < (read-only) for cross-user flock detection
#   - Path resolution: use realpath (fallback cd+pwd) for robust SCRIPT_DIR
#   - Removed $1 parameter; always uses script's own directory
```

```
# v2.3: Lock file open mode changed from > to <> to avoid unnecessary truncation
```

---
## 14. .gbpbackup_profile配置文件版本历史
```
# v4.0 (2026-05-11) :
#   - Remove readonly SCRIPT_DIR and use conditional assignment instead, to prevent error when sourcing the script multiple times
#   - Change the formula for backup_threads to round up (cores + 1) / 2, aligning with the main script
#   - Correct the default comment value for compress_level from "7" to "5", aligning with the main script
#   - All export values are compatible with both constant values and $() expressions
```

---

## 15. gbpbackup 脚本版本历史

|版本|日期|主要变更|
| ------| ------------| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|v4.1|2026-05-11|修复锁文件 PID 残留（head -1 + 截断写入 ）；修复 `check_db`​ 非 local 变量（显式全局 `_GBP_DATA_DIR`​）；修复 Python 退出码混淆（错误=2，正常=1）；修正日志描述；monitor 脚本：只读锁检测兼容跨用户、realpath 路径解析、移除 `$1` 传参|
|v4.0|2026-04-29|修复 `local var=$(cmd)`​ 在 `set -e`​ 下不传播退出码；`compress_args`​ 改为真正 bash 数组；`build_compress_args`​ 默认值统一为 5；增加归档清理文件数统计输出；修复 profile 加载兼容性；修复 `GAUSSHOME` unbound variable|
|v3.9|2026-04-23|修复 `pg_archivecleanup` 参数错误导致归档重置；增加截止日期计算日志；改为自然日期保留策略|
|v3.8|2026-04-10|统一日志格式（时间戳 + [SCRIPT] + [级别]）；Python 内嵌代码日志格式与 bash 同步|
|v3.7|2026-04-09|提取远程参数处理为函数；增量备份有效性检查（Python JSON 解析，7 天内有效全量）；自动降级为全量备份；备份完成后自动执行 validate 和 checkexpired ; 脚本正式增加版本历史公告|
|v3.6|2026-03-15|新增独立 `set-config` 命令；锁文件改为本地目录；提取 set-config 核心逻辑|
|v3.5|2026-02-01|日志自动过期清理；动态构建压缩参数（修复 compress-level=0 的错误）|
|v3.4|2026-01-05|日志文件名按日期归档；增加备机备份模式（`is_standby_backup`）|
|v3.3|2025-12-26|日志按操作类型分目录存储|

```
# Version Description   : v4.0 (2026-05-09)
#     - Fix : local var=$(cmd) pattern under set -e does not propagate exit code;
#             split declaration and assignment throughout
#     - Fix : ${compress_args[@]} on plain string variable — use read -ra for real array
#     - Fix : build_compress_args internal default :-7 inconsistent with global default 5
#     - Fix : trailing backslash before #--progress comment (syntax ambiguity removed)
#     - Fix : $($use_remote && echo ...) replaced with explicit [[ ]] conditional
#     - Fix : profile sourcing temporarily disables set -e/-u to tolerate $() failures
#     - Fix : Use <> (read/write) instead of > (write) to prevent truncating the PID
#     - Feature : Add the step of reloading configuration file before performing the backup operation.
#     - Feature : cmd_archive_clean now reports before/after/removed file count statistics
#     - Feature : archive_dir uses -maxdepth 1 for accurate count
#     - Feature : By comparing before and after using `wc -l`, clearly output "removed: N files".
#     - Unify  : default values aligned between gbpbackup and .gbpbackup_profile
```

```
# Version Description   : v3.9 (2026-04-23)
#     - Fix : Fixed the parameter error caused by improper usage of pg_archivecleanup, which led to the reset of the archive.
#     - Refactor: Increase the log output of the files for the selected time points
#     - Refactor: Natural time-based retention, select most recent completed backup before cutoff
```

```
# Version Description   : v3.8 (2026-04-10)
#     - Feature: Unified logging format with timestamp, component tag [SCRIPT], and severity level [INFO|WARN|ERROR|OK]
#     - Refactor: Replace all echo "[LEVEL]" statements with structured log functions (log_info, log_warn, log_error, log_ok)
#     - Improvement: Python embedded code now uses consistent logging format with bash components
#     - Code: Standardized log output for better readability and monitoring integration
```

```
# Version Description   : v3.7 (2026-04-09)
#     - Refactor: Extract remote parameter handling into check_use_remote() and build_remote_params() functions 
#                 (supporting 'conn' and 'remote' parameter types)
#     - Feature: Intelligent incremental backup with auto-fallback - switches to FULL backup automatically 
#                 when no valid base backup exists within 7 days (has_valid_backup function with Python JSON parsing)
#     - Feature: Add Python-based backup validity checking with accurate time validation (fallback to basic check if Python unavailable)
#     - Refactor: Extract compression parameter building to build_compress_params() function (logs to stderr, returns params)
#     - Improvement: Backup workflow now chains validate and checkexpired automatically after backup completion
#     - Fix: Re-enable --progress flag in gs_probackup backup command (was commented in v3.6)
#     - Fix: Correct argument parsing syntax error ($#) in cmd_backup while loop
#     - Code: Optimize variable scope handling for use_remote in remote backup scenarios
#     - Fix: Unified logging for chained backup workflow(backup → validate → checkexpired now all log to backup/*.log)
```