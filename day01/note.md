# First Boot

由於目前開發主機使用的是 64 位元 Linux (AMD64 / x86_64 架構)，而我們要開發的是 32 位元 (x86 / i386) 的作業系統，處理工具鏈 (Toolchain) 的相容性與位元轉換會是第一道關卡。我們不會在主機上直接亂裝套件，而是會利用 Docker 建立一個乾淨、可拋棄的編譯環境，並透過 QEMU 來進行開機模擬與測試。

## 實作步驟
1. 安裝Docker
2. 建立編譯環境 (Dockerfile)
3. 撰寫系統進入點 (boot.S)
4. 記憶體佈局設定 (linker.ld)
5. 自動化建置腳本 (Makefile)
6. 執行與驗證

### Step 1. 安裝Docker
參考[Docker Engine on Ubuntu 18.04 安裝示範](https://ithelp.ithome.com.tw/m/articles/10236077)

#### 1. Update Software Repositories

安裝前先更新本地資料庫以確保我們可以存取到最新版本。
```
sudo apt-get update
```

#### 2. Uninstall Old Versions of Docker (Optional)
先確認環境中是否已有docker存在，若有則須執行解除安裝來避免衝突。
```
sudo apt-get remove docker docker-engine docker.io
```

#### 3. Install Docker on Ubuntu
```
sudo apt install docker.io
```
#### 4. Start and Automate Docker
需要將Docker服務設置為啟動時常駐自動執行。
```
sudo systemctl start docker
sudo systemctl enable docker
```

#### 5. Check Docker Information
確認docker完整的預設配置資訊清單
```
docker info
```
此時可能會遇到以下問題
```shell
$ docker info
Client:
 Version:    26.1.3
 Context:    default
 Debug Mode: false

Server:
ERROR: permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get "http://%2Fvar%2Frun%2Fdocker.sock/v1.45/info": dial unix /var/run/docker.sock: connect: permission denied
errors pretty printing info
```
這個錯誤是因為目前的 Linux 使用者帳號沒有權限存取 Docker 的背景服務通訊端（`/var/run/docker.sock`）。

預設情況下，這個通訊端檔案的擁有者是 root，只有 root 或屬於 docker 群組的使用者才能存取它。

如果只是偶爾執行，可以在你的 Docker 指令前面加上 sudo 來取得最高權限：
```shell
sudo docker info
```

#### 6. Fix environment error
為了不要每次打指令都要輸入 `sudo`，可以將目前的帳號加入 `docker` 群組。依照以下步驟執行：

(1) **建立 docker 群組:** 通常安裝時已建立，但確保萬無一失.
```bash
sudo groupadd docker
```

(2) **將目前使用者加入群組:**
這會把你的帳號（`$USER`）新增到 `docker` 群組中：

```bash
sudo usermod -aG docker $USER
```


(3) **套用群組變更:** 不用登出直接生效的方法.
輸入以下指令讓系統重新載入你的群組權限（或者你也可以選擇登出再重新登入系統）：

```bash
newgrp docker
```


(4) **驗證設定是否成功:**
執行以下指令測試。如果沒有出現 `permission denied` 錯誤，就代表設定成功了：

```bash
docker run hello-world
```
> **安全性提醒：** 將使用者加入 `docker` 群組等同於給予該使用者系統的 `root` 級別權限，這在個人開發機上很常見，但若是正式的生產伺服器，請務必評估安全性。

執行完上述指令後再次確認：
```
docker info
```
若出現類似以下的詳細資訊則代表安裝成功：
```
$ docker info
Client:
 Version:    26.1.3
 Context:    default
 Debug Mode: false

Server:
 Containers: 0
  Running: 0
  Paused: 0
  Stopped: 0
 Images: 0
 Server Version: 26.1.3
 Storage Driver: overlay2
  Backing Filesystem: extfs
  Supports d_type: true
  Using metacopy: false
  Native Overlay Diff: true
  userxattr: false
 Logging Driver: json-file
 Cgroup Driver: cgroupfs
 Cgroup Version: 1
 Plugins:
  Volume: local
  Network: bridge host ipvlan macvlan null overlay
  Log: awslogs fluentd gcplogs gelf journald json-file local splunk syslog
 Swarm: inactive
 Runtimes: io.containerd.runc.v2 runc
 Default Runtime: runc
 Init Binary: docker-init
 containerd version: 
 runc version: 
 init version: 
 Security Options:
  apparmor
  seccomp
   Profile: builtin
 Kernel Version: 5.15.0-139-generic
 Operating System: Ubuntu 20.04.6 LTS
 OSType: linux
 Architecture: x86_64
 CPUs: 8
 Total Memory: 7.461GiB
 Name: weizhih-Modern-15-A11MU
 ID: 874e93d5-ccdc-43e8-b233-9c42a0622fff
 Docker Root Dir: /var/lib/docker
 Debug Mode: false
 Experimental: false
 Insecure Registries:
  127.0.0.0/8
 Live Restore Enabled: false
```

### Step 2. 建立編譯環境 (Dockerfile)
我們需要一個包含 nasm (組譯器)、gcc (編譯器) 和 ld (連結器) 的環境。 須建立一個`Dockerfile`
```dockerfile
FROM debian:bullseye

RUN apt-get update && apt-get install -y \
    nasm \
	build-essential \
	grub-pc-bin \
	grub-common \
	xorriso \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
```
這支 Dockerfile 的主要目的是建立一個用來**開發作業系統 (OS Development)** 或**編譯底層開機映像檔 (Bootable ISO)** 的建置環境。

它打包了寫組合語言、編譯 C 語言，以及製作可開機 ISO 檔所需的所有核心工具。以下是逐行的詳細說明：

#### (1) 基礎映像檔

```dockerfile
FROM debian:bullseye
```

這行指定使用 **Debian 11 (代號 bullseye)** 作為基礎作業系統。這是一個非常穩定且在開源社群中廣泛使用的 Linux 發行版。

#### (2) 安裝核心工具與清理

```dockerfile
RUN apt-get update && apt-get install -y \
    nasm \
    build-essential \
    grub-pc-bin \
    grub-common \
    xorriso \
    && rm -rf /var/lib/apt/lists/*
```

這段指令會更新套件庫並安裝 5 個關鍵工具。這些工具的組合是自製作業系統 (如寫一個簡單的 Kernel) 的標準配備：

* **`nasm`** (Netwide Assembler)：最受歡迎的 x86 組譯器。開發作業系統時，通常需要用組合語言來撰寫最底層的開機引導程式 (Bootloader) 或中斷處理。
* **`build-essential`**：Debian 的核心開發包，裡面包含了 `gcc` (C 語言編譯器)、`make` (自動化建置工具) 等。用來編譯你的 C 語言 Kernel 程式碼。
* **`grub-pc-bin` & `grub-common`**：GRUB 開機管理程式的相關檔案與工具。當你要製作一個可以用 GRUB 引導開機的系統時會用到。
* **`xorriso`**：一個用來建立 ISO 9660 光碟映像檔的工具。在 OS 開發中，通常會使用 `grub-mkrescue` 指令搭配 `xorriso`，將編譯好的 Kernel 打包成一個可以丟進虛擬機 (如 QEMU 或 VirtualBox) 執行的可開機 ISO 檔。

> **最佳實踐：** 最後一行的 `rm -rf /var/lib/apt/lists/*` 是為了清空 `apt-get update` 下載的暫存檔。這可以顯著縮減最終產生的 Docker Image 體積。

#### (3) 設定工作目錄

```dockerfile
WORKDIR /workspace
```

這行將容器內的預設操作目錄設定為 `/workspace`。

**它的實際作用：** 當你啟動這個容器時，你會直接進入這個資料夾。通常你會將本機端 (Host) 的原始碼目錄掛載 (Mount) 到這個 `/workspace`，讓容器內的編譯器可以直接存取並編譯你的程式碼。

### Step 3. 撰寫系統進入點 (boot.S)
```.S
section .multiboot
align 8
header_start:
	dd 0xe85250d6                ; Multiboot2 魔法數字
	dd 0			     ; 架構 0 (代表 i386)
	dd header_end - header_start ; 標頭總長度
        ; 檢查碼 (Checksum) = -(魔法數字 + 架構 + 長度)
        dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start))
	; ===== 加上官方規定的結束標籤 =======
	dw 0    ; type = 0 (代表結束)
        dw 0    ; flags = 0
        dd 8    ; size = 8 (這兩個 dw 加上一個 dd 剛好佔 8 bytes)
header_end:

section .text
global _start
_start:
    ; VGA 文字模式的記憶體起始位置是 0xb8000
    ; 每個字元佔用 2 bytes：前景色/背景色 (1 byte) + ASCII 碼 (1 byte)
    ; 0x2f 代表綠底白字 (或類似高對比顏色)，0x4f 是 'O'，0x4b 是 'K'
    mov dword [0xb8000], 0x2f4b2f4f

    ; 關閉硬體中斷
    cli

.hang:
    ; 讓 CPU 進入休眠狀態 (Halt)，如果被喚醒則跳回 .hang 繼續休眠
    hlt
    jmp .hang

```
這段程式碼就是上一個步驟的 Dockerfile 要編譯的最佳範例！這是一支**極簡的 32 位元 x86 作業系統核心 (OS Kernel)**。

它的功能非常單純：讓 GRUB 開機管理程式載入它，然後在螢幕左上角印出綠底白字的「OK」，接著讓 CPU 永遠停機休息。

這裡拆解這段程式碼的兩大核心區塊：

#### (1) Multiboot2 標頭 (給 GRUB 看的通行證)
**🔴 首先要知道何謂Multiboot2？**

想像一下，如果世界上每種型號的汽車，都需要用自己專屬形狀的加油槍才能加油，那會是一場災難。在早期的個人電腦世界裡，作業系統的開機就是這種情況：每個作業系統（Windows、Linux、FreeBSD）都有自己專屬的開機程式（Bootloader）。

**Multiboot2 就是一項為了解決這個混亂而誕生的「開放標準（Specification）」。**

由自由軟體基金會（FSF）制定，它定義了**開機管理程式（如 GRUB）與作業系統核心（Kernel）之間該如何溝通**。

只要你的作業系統核心遵守 Multiboot2 的規範（也就是在檔案開頭放入上一段程式碼中的那個「標頭」），GRUB 就會幫你處理掉開機時最痛苦、最繁瑣的底層硬體設定：

1. **切換模式：** 將 CPU 從古老的 16 位元真實模式（Real Mode）切換到 32 位元保護模式（Protected Mode）。
2. **收集硬體資訊：** 幫你偵測電腦有多少記憶體、顯示卡支援什麼解析度，然後整理成一張表格（Multiboot Information Structure）交給你的核心。
3. **通用掛載：** 讓使用者可以在同一個硬碟上安裝幾十個不同的作業系統，並用同一個選單（GRUB 選單）來選擇要啟動哪一個。

簡而言之，Multiboot2 讓 OS 開發者可以專心寫作業系統的功能，而不用去煩惱「如何把作業系統從硬碟安全地拉進記憶體裡執行」。

**🔴 `section .multiboot` 區塊**

它並不是要執行的指令，而是資料。
```.S
section .multiboot
align 8
header_start:
	dd 0xe85250d6                ; Multiboot2 魔法數字
	dd 0			     ; 架構 0 (代表 i386)
	dd header_end - header_start ; 標頭總長度
        ; 檢查碼 (Checksum) = -(魔法數字 + 架構 + 長度)
        dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start))
	; ===== 加上官方規定的結束標籤 =======
	dw 0    ; type = 0 (代表結束)
        dw 0    ; flags = 0
        dd 8    ; size = 8 (這兩個 dw 加上一個 dd 剛好佔 8 bytes)
header_end:
```
這段程式碼之所以被稱為「資料」而不是「執行的指令」，關鍵在於裡面的 **`dd`** 這個關鍵字。

在組合語言中，`dd` 代表 **Define Double Word（定義雙字組，即 4 個位元組）**。當組譯器（如 `nasm`）看到 `dd` 時，它不會把它轉換成 CPU 懂得執行的動作（例如加減乘除或移動資料），而是會**直接把後面的數字原封不動地硬塞進最後編譯出來的檔案裡**。

我們來對照一下這段內容實際編譯後的樣子：

| 組合語言原始碼 | 實際編譯進檔案的二進位資料 (Hex) | GRUB 的視角 |
|---|---|---|
| `section .multiboot` | \*(僅為區段宣告，不產生資料)\* | 「這個區段我要優先載入，確保它在檔案最前面。」 |
| `align 8` | \*(填充至 8 bytes 對齊邊界)\* | 「標頭位址必須對齊，否則我找不到它。」 |
| `dd 0xe85250d6` | `D6 50 52 E8` (小端序) | 「啊！這就是 Multiboot2 的魔法數字！這是一個合法的核心！」 |
| `dd 0` | `00 00 00 00` | 「架構代碼是 0，代表這是 32 位元保護模式的 i386 架構。」 |
| `dd header_end - header_start` | `18 00 00 00`（長度 24 bytes）| 「整個標頭佔 24 個位元組，我只讀這個範圍內的資料。」 |
| `dd 0x100000000 - (魔法數字 + 架構 + 長度)` | 計算出的檢查碼 | 「四個欄位加總必須等於 0（mod 2³²），資料完整，可以繼續！」 |
| `dw 0` | `00 00` | 「Tag Type = 0，這是『結束標籤』，後面沒有其他 Tag 了。」 |
| `dw 0` | `00 00` | 「Flags = 0，這個結束標籤不帶任何旗標。」 |
| `dd 8` | `08 00 00 00` | 「這個 Tag 的大小是 8 bytes（2 × dw + 1 × dd），結構完整。」 |

**記憶體排列示意圖:**

```
位址偏移  內容 (Hex)          說明
+0000    D6 50 52 E8         魔法數字 0xe85250d6
+0004    00 00 00 00         架構 = 0 (i386)
+0008    18 00 00 00         標頭長度 = 24 bytes
+000C    ?? ?? ?? ??         Checksum（由計算決定）
+0010    00 00               結束 Tag type = 0
+0012    00 00               結束 Tag flags = 0
+0014    08 00 00 00         結束 Tag size = 8
         ↑
      header_end（總計 24 bytes）
```

**🔺幾個關鍵概念補充:**

**①`align 8` 的作用**

`align 8` 的意思是：**強制讓下一個資料的起始位址，必須是 8 的倍數**。

如果位址剛好已經是 8 的倍數了就什麼都不做，如果不是，就自動填充 `0x00` 直到對齊為止。

實際的記憶體排列示意:

假設在 `header_start` 之前，已經有一些資料，導致目前的位址落在了 `0x1002`：

**❌ 沒有 `align 8` 的情況:**

```
位址      內容
0x1000    ...（前面的資料）
0x1001    ...
0x1002    D6 50 52 E8   ← header_start 從奇怪的位址開始
0x1006    00 00 00 00
0x100A    18 00 00 00
...
```

GRUB 要尋找 Multiboot2 標頭時，規範要求它必須從 **8 bytes 對齊的邊界** 開始搜尋（即 `0x1000`, `0x1008`, `0x1010`...）。由於標頭從 `0x1002` 開始，**GRUB 永遠找不到它**，開機失敗。

**✅ 有 `align 8` 的情況**

```
位址      內容              說明
0x1000    ...（前面的資料）
0x1001    ...
0x1002    00 00 00 00 00 00 ← 自動填充 6 個 0x00，直到下一個 8 的倍數
0x1008    D6 50 52 E8       ← header_start 剛好從 0x1008 開始（8 的倍數）✅
0x100C    00 00 00 00
0x1010    18 00 00 00
0x1014    ?? ?? ?? ??       Checksum
0x1018    00 00             End Tag type
0x101A    00 00             End Tag flags
0x101C    08 00 00 00       End Tag size
```

GRUB 每次跳 8 bytes 去搜尋魔法數字 `0xe85250d6`，在 `0x1008` 就能找到，開機成功。

**為什麼 Multiboot2 規範要求 8 bytes 對齊？**

這是一個 **硬體層面的效能考量**：

| 原因 | 說明 |
|---|---|
| **CPU 讀取效率** | 現代 64-bit CPU 一次讀取 8 bytes，若資料不對齊，CPU 需要讀兩次才能拼出完整資料，效率較差 |
| **GRUB 搜尋效率** | GRUB 掃描核心檔案時，每次跳 8 bytes 去找魔法數字，若不對齊就會直接跳過 |
| **規範一致性** | Multiboot2 官方規範明文規定標頭必須對齊到 8-byte 邊界，否則行為未定義 |

**② 為什麼長度是 24？**

> 標頭包含：**4 個 `dd`（各 4 bytes）+ 1 個 `dw`（2 bytes）+ 1 個 `dw`（2 bytes）+ 1 個 `dd`（4 bytes）**


$4 \times 4 + 2 + 2 + 4 = 24 \text{ bytes}$


**③ Checksum 的計算邏輯**

Multiboot2 規範要求以下四個欄位加總必須為 0（在 32 位元無號整數下）：

$\text{magic} + \text{arch} + \text{length} + \text{checksum} \equiv 0 \pmod{2^{32}}$

因此：

$\text{checksum} = 2^{32} - (\text{0xe85250d6} + 0 + 24)$

用 `0x100000000` 是因為組合語言中不能直接表達 2³²，這是常見的等效寫法。

**④ 結束標籤（End Tag）的作用**

Multiboot2 標頭是由一系列 **Tag（標籤）** 組成的，每個 Tag 都有 `type`、`flags`、`size` 三個欄位。
根據 Multiboot2 官方規格書（Multiboot2 Specification），每個 Tag 的結構長這樣：


\begin{array}{|c|c|c|}
\hline
\text{Offset} & \text{大小} & \text{欄位名稱} \\
\hline
0 & \text{2 Bytes (dw)} & \text{type} \\
2 & \text{2 Bytes (dw)} & \text{flags} \\
4 & \text{4 Bytes (dd)} & \text{size} \\
\hline
\end{array}

* **Type = 0** 是官方規定的「哨兵值」，告訴 GRUB：

    > 「Tag 清單到這裡結束了，不用再往下讀了。」

    就像 C 語言字串結尾的 `'\0'` 一樣，是一個**終止符**的概念。

* **flags 欄位的功用:**

    `flags` 欄位的功用是告訴 Bootloader（例如 GRUB）：**「如果你看不懂這個 Tag，你應該怎麼處理它？」**

    目前規格書只定義了 **Bit 0** 這一個位元：

	| Bit 0 的值 | 意義 |
	|---|---|
	| `0` | 如果 Bootloader 不認識這個 Tag，**可以安全地忽略它，繼續開機**。 |
	| `1` | 如果 Bootloader 不認識這個 Tag，**必須強制放棄開機並回報錯誤**。 |

    簡單說：`flags` 是一個「**讀不懂怎麼辦？**」的緊急應對方案。

    然而理論上，End Tag 的 `flags` 完全沒有實質意義，原因如下：

    1. **所有的 Bootloader 都必須認識 `type = 0`**，因為這是規格書規定的強制標準。
    2. **既然它一定看得懂**，`flags` 的「看不懂怎麼辦」邏輯就永遠不會被觸發了。
    3. 所以 `flags = 0` 在 End Tag 裡面純粹是為了**符合 Tag 的固定結構格式**而存在，它就是一個佔位子的填充值（Padding）。



    儘管如此，**`flags` 必須存在，而且不能省略！**

    這是因為 GRUB 在解析 Multiboot2 Header 的時候，是用**固定的 Struct 結構    **來讀取每一個 Tag 的。它會直接依照記憶體位址偏移量（Offset）來抓資料：
    \*   偏移 `+0`（2 Bytes）= `type`
    \*   偏移 `+2`（2 Bytes）= `flags`
    \*   偏移 `+4`（4 Bytes）= `size`

    如果你把 `flags` 這個 `dw 0` 拿掉，整個 Tag 的記憶體排列就會整個往前移位，GRUB 會把 `size` 的前兩個 Byte 誤認為是 `flags`，把後面的資料誤認為是 `size`，最終解析出一個完全錯誤的結構，導致開機失敗。


**🔴 為什麼Magic Number 是 0xe85250d6？**

這在資訊科學中被稱為「魔法數字（Magic Number）」。

它其實沒有什麼高深的物理或數學意義，它就只是一組**被刻意挑選出來、極不容易與一般資料撞名的隨機亂碼**。

開機程式（GRUB）在掃描你的檔案時，不會去逐行分析你的程式碼邏輯，它只會像找條碼一樣，在檔案最前面的 8KB 內尋找這串特定的 16 進位數字。一旦找到，GRUB 就會認定：「這不是普通的文字檔或圖片，而是一個可開機的核心」。

**一個有趣的歷史小彩蛋：**

在 Multiboot2 出現之前，還有一個第一代標準叫做 **Multiboot1**。當時的開發者比較有幽默感，他們為 Multiboot1 選定的魔法數字是：

**`0x1BADB002`**

你可以試著用英文唸唸看這串 16 進位數字——它聽起來就像 **"One bad boot"（一次糟糕的開機）**。

後來因為硬體技術演進，推出了第二代的 Multiboot2 規範。為了區分第一代與第二代，開發者需要一組全新的魔法數字，這次他們就沒有再玩諧音梗了，而是直接產生了 `0xe85250d6` 這組隨機但絕對獨特的數字作為新一代的識別證。

#### (2) 核心主程式 (印出字串與停機)
```.S
section .text
global _start
_start:
    ; VGA 文字模式的記憶體起始位置是 0xb8000
    ; 每個字元佔用 2 bytes：前景色/背景色 (1 byte) + ASCII 碼 (1 byte)
    ; 0x2f 代表綠底白字 (或類似高對比顏色)，0x4f 是 'O'，0x4b 是 'K'
    mov dword [0xb8000], 0x2f4b2f4f

    ; 關閉硬體中斷
    cli

.hang:
    ; 讓 CPU 進入休眠狀態 (Halt)，如果被喚醒則跳回 .hang 繼續休眠
    hlt
    jmp .hang
```

**🔴 為什麼這段叫「主程式」？**

因為前面 `section .multiboot` 的內容只是單純的「開機檢查資料」，GRUB 讀完、確認過後就不會再去管它了。

**🔴 `section .text`（宣告程式碼區塊）**

在二進位檔案或記憶體中，資料是需要分類存放的（例如：哪些是可執行的指令？哪些是唯讀的字串？哪些是可以修改的變數？）。`section` 指令就是用來劃分這些區域的。

* **`.text`**：是一個標準的作業系統命名慣例，代表「可執行的程式碼（Code）」。
* **它的意思：** 告訴組譯器說：「從這行開始往下的所有內容，都是 CPU 要執行的指令（如 `mov`, `cli`, `hlt`），請把我編譯成機器碼，並在執行時給予這塊記憶體『可執行』的權限。」
* *延伸思考：相對的，如果是放全域變數的區域通常會宣告為 `section .data`，放開機檢查碼的會像我們前面寫的 `section .multiboot`。*

**🔴 `global _start`（公開程式進入點）**

這行指令由兩個部分組成，是用來幫程式標示「起跑線」的：

* **`_start`**：是程式碼中的一個標籤（Label）。在 Linux 和核心開發的世界裡，`_start` 是約定俗成的**程式進入點（Entry Point）**，也就是整個程式被載入後，第一條要被執行的指令位置。
* **`global`**：意思是「公開／全域」。如果沒有加上 `global`，這個 `_start` 標籤就只有這支 `.asm` 檔案自己內部看得見。
* **它的意思：** 告訴組譯器說：「請把 `_start` 這個起跑線的位置公開出去！」這樣一來，後面負責將各個檔案打包在一起的連結器（Linker）才能找得到這個起跑線，並把這個位址寫進最終的核心檔案中。

**🔴 總結前兩行的關係**
```.s
section .text
global _start
```
這兩行合起來的白話文意思就是：

> 「各位注意，後面這段是**可以執行的程式碼**（`section .text`），而且我把整個作業系統核心的**起跑線**設在這裡，並公開給所有人看（`global _start`），開機管理程式（GRUB）載入後請直接從這裡開始跑！」

**🔴 `_start:`（程式開始執行的地方）** 
當 GRUB 把控制權真正交給你的作業系統時，CPU 的指標會直接跳到 `_start:` 這個標籤的位置，並**從這裡開始一條一條執行指令**（先搬移資料印出 OK，再關閉中斷，最後進入無窮的休眠迴圈）。這就是作業系統核心真正「活起來」並執行任務的地方！

**🔴 印出「OK」**

`mov dword [0xb8000], 0x2f4b2f4f` 這行指令非常經典。在底層開發中，我們沒有 `printf` 可以用，必須直接把資料寫入顯示卡指定的記憶體位址 (`0xb8000` 是 VGA 文字模式的起始位址)。

因為 x86 架構是**小端序 (Little-Endian)**，資料在記憶體中會反過來存。這個 4 bytes (DWORD) 的數字寫入後，記憶體的實際排列會是這樣：

| 記憶體位址 | 寫入數值 (Hex) | 實際意義 |
| --- | --- | --- |
| `0xb8000` | `0x4F` | ASCII 字元 **'O'** |
| `0xb8001` | `0x2F` | 顏色屬性 (綠底白字) |
| `0xb8002` | `0x4B` | ASCII 字元 **'K'** |
| `0xb8003` | `0x2F` | 顏色屬性 (綠底白字) |

**🔴 讓 CPU 休息**

在此例中，螢幕印出字後，作業系統沒有其他事情可做了：

* **`cli` (Clear Interrupts)**：關閉硬體中斷。因為還沒設定「中斷描述表 (IDT)」，如果這時候鍵盤被按下或時鐘發出訊號，CPU 會不知道怎麼處理而直接崩潰 (Triple Fault) 重開機。
* **`.hang` 迴圈**：使用 `hlt` 讓 CPU 進入低功耗休眠。如果某些無法被遮蔽的中斷 (NMI) 喚醒了 CPU，下一行的 `jmp .hang` 會強制它立刻跳回去繼續睡。

### Step 4. 記憶體佈局設定 (linker.ld)
```ld
ENTRY(_start)

SECTIONS {
    /* 核心載入起始位址：1MB */
    . = 1M;

    /* 將 multiboot 標頭放在最前面，這非常重要，否則 Bootloader 找不到 */
    .text BLOCK(4K) : ALIGN(4K) {
        *(.multiboot)
        *(.text)
    }

    /* 唯讀資料區段 */
    .rodata BLOCK(4K) : ALIGN(4K) {
        *(.rodata)
    }

    /* 可讀寫資料區段 */
    .data BLOCK(4K) : ALIGN(4K) {
        *(.data)
    }

    /* 未初始化資料區段 */
    .bss BLOCK(4K) : ALIGN(4K) {
        *(COMMON)
        *(.bss)
    }
}

```
這段程式碼叫做 **Linker Script（連結腳本）**，在編譯流程中通常檔名會叫做 `linker.ld`。它是整個作業系統開發計畫的**第三塊拼圖**！

如果之前的組合語言是「建材」，那這段腳本就是「建築藍圖」**。它負責告訴**連結器（Linker）：要把編譯好的機器碼和資料，以什麼順序、擺放在記憶體的哪一個精確位置，好讓 GRUB 開機時不會錯亂。

以下逐段拆解這張藍圖的設計：

**🔴指定起跑線**

```ld
ENTRY(_start)
```

這行呼應了我們前一步在組合語言寫的 `global _start`。它直接告訴連結器：「整個作業系統被載入後，**第一條要執行的指令就在 `_start` 這個位置**。」

**🔴設定起跑點為 1MB 記憶體處**

```ld
. = 1M;
```

在連結腳本中，`.` 叫做**位置計數器（Location Counter）**。這行意思是把目前的記憶體指標直接指定到 **1MB (`0x100000`)** 的地方。

> **為什麼是 1MB？** 因為在 x86 電腦開機時，1MB 以下的低位元記憶體有很多固定用途（例如 BIOS 資料、VGA 顯示記憶體 `0xb8000` 等）。為了安全，現代作業系統核心通常都會從 1MB 以上的「高位元記憶體（Upper Memory）」開始載入。

**🔴 最關鍵的安排：把 Multiboot 放最前面**

```ld
.text BLOCK(4K) : ALIGN(4K) {
    *(.multiboot)
    *(.text)
}
```

這一區段的安排**超級重要**，作業系統能不能成功開機全看這裡：

首先，**`ALIGN(4K)`** 把這個區段以 4KB（一個記憶體分頁的大小）為單位對齊，確保執行效率。

接著當連結器（Linker）在讀取這段腳本時，就跟我們人類讀書一樣，是「從上到下」依序處理的大直性子。在大括號 `{ }` 裡面，你先寫了誰，它就會先把誰排進最終產出的檔案裡。

我們可以把這個過程視覺化成一個排隊的隊伍：

```text
輸出檔案的映像檔內部結構：
┌──────────────────────────┐  ◄── 1MB 起始點
│  所有檔案的 .multiboot    │  ◄── 先排這裡（因為寫在上面）
├──────────────────────────┤
│  所有檔案的 .text        │  ◄── 緊接著排後面（因為寫在下面）
└──────────────────────────┘

```

這裡的 `*` 是一個萬用字元（Wildcard），代表「所有輸入的物件檔案（`.o` 檔）」。所以這段程式碼的白話文運作邏輯是：

1. 連結器看到 `*(.multiboot)`：它會去翻遍你提供給它的所有編譯好的物件檔案，把裡面所有標記為 `section .multiboot` 的資料通通收集起來，**整整齊齊地排在最前面**。
2. 連結器看到 `*(.text)`：等上面的 `.multiboot` 全部排完之後，它才去收集所有檔案裡的 `section .text`（也就是你的主程式程式碼），**接著塞在後面**。

**如果顛倒過來寫會發生什麼事？**

如果你不小心把兩行寫反了，變成這樣：

```ld
*(.text)
*(.multiboot)
```

連結器就會把 `_start` 主程式塞在最開頭。雖然程式碼很少，但只要它佔用的空間讓後面的 `.multiboot` 標頭被擠出檔案開頭前 8KB 的範圍，GRUB 開機時就會因為找不到魔法數字而直接放棄載入。因此如果沒有這個強制造型，編譯器可能會把一般程式碼往前放，把 Multiboot 擠到後面，GRUB 找不到就會回報 `Error 13: Invalid or unsupported executable format`。

所以這個「上與下」的寫法順序，就是決定檔案內部構造的絕對關鍵！

**🔴 其他標準資料分區**

剩下的部分是把其他類型的資料分門別類放好，並同樣做 4KB 對齊：

* **`.rodata` (Read-Only Data)**：存放唯讀資料，像是程式裡寫死的字串（例如 `"Hello World"`）。
* **`.data`**：存放已經初始化（有給初始值）的全域變數。
* **`.bss`**：存放未初始化的全域變數。這塊區域在檔案中不佔空間，但作業系統載入時會自動在記憶體中配置並清空為 0。

**🔺 這些區塊的存在必要性為何？**

對於我們剛剛寫的那個只印出「OK」的極簡核心，這些區塊完全不建立是「不會有問題」的；但只要程式碼開始變大（例如加入 C 語言、宣告變數或字串），它們就變成「必須建立」的區塊。

以下詳細分析如果沒有建立這些區塊，各自會帶來什麼災難，以及它們到底是不是固定的。

**🔺如果「程式碼有用到」但「連結腳本沒建立」會怎樣？**

如果程式（例如寫了 C 語言）宣告了全域變數或字串，但在連結腳本（Linker Script）中卻把這三個區塊刪掉了，連結器（Linker）在打包時會面臨嚴重的後果：

**(1) 產生「孤兒區段 (Orphan Sections)」導致開機失敗**

GNU 連結器發現程式碼裡有資料，但藍圖（Linker Script）沒寫地方放時，它不會直接報錯，而是會自作聰明地變成「孤兒區段」，隨便找個空位把 `.data` 或 `.rodata` 塞進去。

* **後果：** 連結器很可能會把它們塞在 `.multiboot` 的前面，直接把魔法數字擠出前 8KB 的安全範圍。結果就是 **GRUB 找不到標頭，作業系統直接開機失敗**。

**(2) 各區段各自造成的致命問題**

如果在連結腳本中強行把它們「丟棄（Discard）」，或者因為沒有妥善配置導致記憶體錯亂，會發生以下問題：

| 缺少或錯置的區段 | 導致的具體問題 | 為什麼會這樣？ |
| --- | --- | --- |
| **`.rodata`** (唯讀資料) | 程式中的字串（如 `"Hello"`）直接消失，或者**程式執行到一半直接崩潰（Crash）**。 | 字串如果被錯誤地放進不可讀取的區域，CPU 讀取時會觸發保護機制而當機；或者如果變成了「可寫入」，駭客就能輕易修改你的唯讀字串，造成資安漏洞。 |
| **`.data`** (已初始化變數) | 全域變數**全部失去初始值**。例如寫 `int hp = 100;`，進遊戲後 HP 卻變成 `0` 或隨機的亂碼。 | 因為連結器不知道要把 `100` 這個數字存在檔案的哪裡，開機載入時處理器就無法把 `100` 放進該變數的記憶體位址。 |
| **`.bss`** (未初始化變數) | 1. 變數裡全部塞滿**隨機的恐怖垃圾資料**。2. **開機映像檔（ISO）體積暴增數百倍**。 | 1. BSS 的核心功能是「開機時自動清空為 0」。沒有它，變數就會繼承記憶體剛通電時的隨機雜訊。2. 如果不用 BSS，硬把這些沒初始化的變數塞進 `.data`，編譯器就必須在 ISO 檔案裡塞滿幾百萬個 `0` 來填塞空間，導致檔案變得極大。 |


**🔺他們是固定要建立的區塊嗎？**

不是硬性規定的，但它是現代作業系統與編譯器的「標準普通話」。

**(1) 硬體（CPU）並不知道什麼是 `.data` 或 `.bss`**

對 CPU 來說，記憶體就只是存放二進位數字的地方，它根本不在乎這塊區域叫 `.text` 還是 `.data`。理論上，你高興的話，可以在組合語言裡自己發明新名字，例如寫 `section .my_magic_variables`。

**(2) 但編譯器（如 GCC）和檔案格式（如 ELF）認得它們**

當你使用 Dockerfile 裡的 `gcc` 來編譯 C 語言時，GCC 只要看到你寫：

* `const char* msg = "Hello";` ➔ 它就**固定**會把這段丟進 `.rodata`
* `int a = 5;` ➔ 它就**固定**會把這段丟進 `.data`

因為編譯器產生的零件（物件檔案）已經寫死了這些名字，你的連結腳本（Linker Script）就必須跟著寫出這些名字來接收它們。這就是為什麼在絕大多數的作業系統開發教學中，你都會看到這幾個雷打不動的固定區塊。

**🔴 總結**

這段腳本做的事情只有一件：

> 「把起跑點設在記憶體的 1MB 位置。排隊的時候，**`.multiboot` 標頭站第一個**，`.text` 程式碼站第二個，後面再依序排唯讀資料、可讀寫資料和未初始化資料，而且每隊出發前都要做好 4KB 對齊！」

### Step 5. 建立GRUB 開機管理程式的設定檔(`grub.cfg`)
這支 `grub.cfg` 就是 **GRUB 開機管理程式的「點歌單」（設定檔）**。

當你用虛擬機啟動剛剛做好的 ISO 光碟時，GRUB 會是第一個跳出來的軟體。這支檔案的作用，就是告訴 GRUB：**「請在畫面上秀出哪些作業系統讓使用者選，以及當使用者選了之後，要去哪裡撈核心檔案來開機。」**

它的運作邏輯非常直覺：

```cfg
menuentry "myos" {
	multiboot2 /boot/myos.bin
}

```

(1) `menuentry "myos" { ... }`

* **做什麼：** 在開機的藍色選單畫面上，建立一個可選的項目。
* **引號裡的 `"myos"`：** 就是顯示在畫面上的名字。你可以在這裡改成 `"My Awesome OS v1.0"`，畫面就會跟著變。

(2) `multiboot2 /boot/myos.bin`

這是整支檔案**最核心的指令**，它對 GRUB 下達了兩個命令：

* **`/boot/myos.bin`（去哪裡找）：** 告訴 GRUB 核心檔案在光碟內部的路徑。
* **`multiboot2`（用什麼協定開啟）：** 告訴 GRUB：「這不是普通的 Linux，這是一個符合 **Multiboot2 規範** 的微型核心。」GRUB 聽到之後，就會啟動內建的 Multiboot 解析器，去讀取我們在 `boot.S` 寫的魔法數字（Magic Number），並把核心載入到記憶體的 1MB 位置。

### Step 6. 自動化建置腳本 (Makefile)
```Makefile
# 我的主機是 amd64，編譯目標也是 x86 (elf32)，統一使用 linux/amd64
DOCKER_CMD = docker run --platform linux/amd64 --rm -v $(PWD):/workspace -w /workspace os-builder

all: build-env myos.bin myos.iso

build-env:
	docker build --platform linux/amd64 -t os-builder .

# 打包 ISO 的步驟
myos.iso: myos.bin grub.cfg
	mkdir -p isodir/boot/grub
	cp myos.bin isodir/boot/myos.bin
	cp grub.cfg isodir/boot/grub/grub.cfg
	$(DOCKER_CMD) grub-mkrescue -o myos.iso isodir
	rm -rf isodir

myos.bin: boot.o
	$(DOCKER_CMD) ld -m elf_i386 -n -T linker.ld -o myos.bin boot.o

boot.o: boot.S
	$(DOCKER_CMD) nasm -f elf32 boot.S -o boot.o

clean:
	rm -f *.o *.bin *.iso

```
這段程式碼是一個 **`Makefile`（自動化建置腳本）**。它的主要作用是把之前討論的**所有拼圖**（Dockerfile 環境、組合語言 `boot.S`、連結腳本 `linker.ld`）全部串聯起來，實現**一鍵自動化編譯與打包**。

只要你在終端機輸入 `make`，它就會自動幫你做完從「建立環境」到「產出可開機 ISO 檔」的所有繁瑣步驟。

以下詳細拆解這個自動化流程的每個部分：

**🔴 核心工具宣告：Docker 虛擬指令**

```makefile
# 我的主機是 amd64，編譯目標也是 x86 (elf32)，統一使用 linux/amd64
DOCKER_CMD = docker run --platform linux/amd64 --rm -v $(PWD):/workspace -w /workspace os-builder
```

這行定義了一個重複使用的變數 `$(DOCKER_CMD)`。當後面的步驟需要用到 `nasm` 或 `ld` 時，它並不是直接用本機電腦的工具，而是**呼叫 Docker 容器進來幫忙**。

* `docker run`：Docker 中最常用也最核心的指令，它的白話意思是：「利用指定的映像檔（Image）作為範本，建立並啟動一個全新的容器（Container）來執行任務。」在這個 Makefile 例子中，docker run ... os-builder 就是告訴 Docker：「請幫我用 os-builder 這個環境範本，立刻變出一個活生生的 Linux 虛擬小房間（容器），並在裡面執行我交給你的編譯指令（如 nasm 或 ld）。」
* `--platform linux/amd64`：強制指定使用 64 位元 Linux 環境來執行工具（因為我的主機是 amd64）。
* `--rm`：Remove（刪除） 的縮寫，意思是：「當這個容器執行完任務並關閉後，立刻自動把這個容器的本體刪除。」
    * 為什麼這個參數在 Makefile 裡非常重要？
        * 預設情況下，Docker 容器在執行完裡面的指令後，雖然會變成「停止運作（Exited）」狀態，但它的「屍體」（也就是該次執行的容器紀錄與暫存狀態）依然會殘留在你的硬碟裡。
        * 如果 Makefile 裡沒有加上 --rm：
            * 每當你輸入一次 make，Docker 就會建立 3 個新的容器來處理 nasm、ld 和 grub-mkrescue。
            * 編譯完後，這 3 個容器就會變成死掉的狀態留在硬碟裡。
            * 如果你編譯了 100 次，硬碟裡就會累積 300 個死掉的容器紀錄。
            * 久而久之，這些沒用的殘留容器就會悄悄吃掉你大量的硬碟空間。
        * 加上 `--rm`就能達到「用完即丟，不留垃圾」的效果，編譯完工具關閉的瞬間，容器就自動清空，保證你的電腦硬碟永遠乾淨清爽！
* `-v $(PWD):/workspace`：把在本機的程式碼資料夾，直接掛載（共享）到容器內的 `/workspace` 目錄。
* `-w /workspace`：指定容器一啟動就在工作目錄，方便直接讀取檔案。

**🔴 建置流程拆解（從底層到產出)**

`Makefile` 的運作邏輯是「由上往下看目標，由下往上執行依賴」。當你執行`make`時，等於告訴系統：「幫我執行這份檔案裡的第一個任務。」
又因為`all` 被寫在整份 Makefile 的第一個任務，因此在這個Makefile中，執行 `make` 等於 `make all`，接著就會觸發執行名叫 `all` 的任務。
```Makefile
all: build-env myos.bin myos.iso
```
當這行指令被觸發時，它本身雖然沒有具體要跑的程式碼，但它會告訴系統：「去幫我檢查並完成後面這三個目標，而且要**由左至右**確認！」

具體來說，它會觸發以下骨牌效應：

**(1) 檢查並執行 `build-env`**

系統會先去找 Makefile 裡面定義的 `build-env` 任務。

* **實際上發生了什麼：** 它會執行 `docker build ...` 指令。
* **結果：** 幫你把包含了 gcc、nasm、grub 的 `os-builder` 開發環境（Docker Image）準備好。如果已經建立過了，它就會秒速確認並跳到下一步。

**(2) 檢查並執行 `myos.bin`**

環境準備好後，系統接著去找 `myos.bin` 這個任務。

* **實際上發生了什麼：** Make 會發現要生出 `myos.bin`，必須先有 `boot.o`。於是它會先呼叫容器裡的 `nasm` 把你的組合語言編譯成 `boot.o`，再呼叫 `ld` 加上藍圖（Linker Script）把它打包成作業系統核心 `myos.bin`。
* **結果：** 你的資料夾裡會多出一個 `myos.bin` 檔案（真正的微型作業系統核心）。

**(3) 檢查並執行 `myos.iso`**

最後，系統去找 `myos.iso` 這個任務。

* **實際上發生了什麼：** 它會建立暫時的資料夾結構（`isodir/boot/grub`），把剛剛產生的 `myos.bin` 和 `grub.cfg` 放進去，然後呼叫容器裡的 `grub-mkrescue` 工具把它們壓成光碟映像檔。
* **結果：** 你的資料夾裡會誕生最終產物：一個名為 **`myos.iso`** 的開機光碟檔。

下面依序說明執行`all`後會執行的各步驟：

**步驟 A：建立 Docker 編譯環境**

```makefile
build-env:
	docker build --platform linux/amd64 -t os-builder .
```

* **做什麼：** 這行指令最後面的那個「點（`.`）」代表由「目前的資料夾」讀取最開始寫的那支 `Dockerfile`。由於當 Docker 收到你指定的資料夾位置（`.`）之後，它內部有一個鐵律：如果使用者沒有特別指定要用哪支檔案，我就自動去這個資料夾裡，尋找一個字元大小寫完全符合、且沒有任何副檔名、名字叫做 `Dockerfile`的檔案。接著會在電腦裡建立一個名為 `os-builder` 的Docker映像檔。
    * **💡 延伸思考：如果我想換檔名怎麼辦？**
        * 如果你今天把檔案改名叫 `MyEnvironment.docker`，這時候原本的指令就會報錯（因為 Docker 在資料夾裡找不到預設的 `Dockerfile`）。
        * 這時候你就必須加上 **`-f`（或 `--file`）** 參數，明確地指路給 Docker 看：
        ```bash
        docker build --platform linux/amd64 -f MyEnvironment.docker -t os-builder .
        ```

* **結果：** 電腦現在擁有了一個裝好 `nasm`、`gcc`、`grub`、`xorriso` 的超完美獨立開發環境 `os-builder`。
* **為何稱為獨立開發環境？**
之所以叫它「獨立開發環境」，是因為它具備了以下幾個非常棒的特性：
1. **工具全包，不弄髒主機：** 所有編譯作業系統需要的底層工具（`nasm`、`gcc`、`grub`、`xorriso`）通通都被關在 `os-builder` 這個「貨櫃（容器）」裡面。你不需要在自己原本的 Windows 或 Mac 電腦上安裝一堆複雜的交叉編譯工具鏈。
2. **絕對的環境一致性：** 這是 Docker 最強大的地方。不管這支程式碼拿到誰的電腦上，只要執行 `make` 建立起 `os-builder`，裡面的 Linux 版本、工具版本、環境變數通通一模一樣。徹底解決了程式設計師最怕的「在我的電腦會通，在你的電腦就爛掉」的窘境。
* 可以把它想像成一個「專為作業系統開發量身打造的免安裝軟體懶人包」。平常它就像個光碟映像檔一樣躺在你的硬碟裡，只有當你在 Makefile 中呼叫 `$(DOCKER_CMD)` 時，它才會瞬間啟動，幫你編譯完程式碼後又揮揮衣袖默默消失，完全不佔用你主機的系統資源。

**步驟 B：把組合語言編譯成物件檔 (Object File)**

```makefile
boot.o: boot.S
	$(DOCKER_CMD) nasm -f elf32 boot.S -o boot.o
```
* **做什麼：** 呼叫 Docker 內的 `nasm` 組譯器。
* **關鍵參數：** `-f elf32`。這行非常關鍵！因為主機是 64 位元的 amd64，但我們的微型核心是 32 位元的 x86。這個參數強迫 `nasm` 將寫有印出 "OK" 的 `boot.S` 編譯成 **32 位元的 ELF 格式物件檔 (`boot.o`)**。
* **為何是先執行這步？**
    * 這裡有一個關於 `make` 工具的核心觀念要先釐清：**Makefile 不是由上往下執行的「外掛劇本」（如 Shell Script），它其實是一張「依賴關係圖」（Dependency Tree）。**
    * 在 Makefile 中，之所以把大目標寫在上面、小零件寫在下面，是為了**方便人類閱讀**（一打開檔案就能看到最終產物是什麼）。
而 `make` 處理時，會自動幫你把這個順序「倒過來」，變成**由底層向上逆向追蹤**，確保每一步的原料都 ready 了，才會真正執行指令！
    * 在實際執行時，電腦運作的順序跟你看到的剛好相反。`make` 的大腦其實是這樣思考的：
        * 第一步：總指揮官下達終極目標
        當你輸入 `make` 時，系統看到第一行：
        ```makefile
        all: build-env myos.bin myos.iso
        ```
        `make` 說：「好！我今天的目標是搞定 `build-env`、`myos.bin` 和 `myos.iso` 這三個東西！」
它會由左至右，一個一個去攻克。

        * 第二步：解開 `myos.bin` 的依賴謎題（順序的關鍵！）
        搞定 `build-env` 後，`make` 接著要處理 `myos.bin`。它在檔案中找到了這條規則：
        ```makefile
        myos.bin: boot.o
        $(DOCKER_CMD) ld ...
        ```
        這行意思其實是：「**想要做出 `myos.bin`，你必須先給我 `boot.o`！**」
這時候，`make` 翻了一下資料夾，發現：「糟糕，現在根本沒有 `boot.o` 這個檔案啊！那我現在還不能執行 `ld` 連結指令。」
於是，`make` 決定**暫停**執行 `myos.bin` 的指令，轉頭去檔案下方尋找：「有沒有人知道怎麼做出 `boot.o`？」

        * 第三步：向下追尋原料 `boot.o`
`make` 在下面找到了這條規則：
        ```makefile
        boot.o: boot.S
        $(DOCKER_CMD) nasm ...
        ```
        這行意思是：「**想要做出 `boot.o`，你必須給我 `boot.S`。**」
`make` 檢查資料夾，發現 `boot.S`（你的組合語言原始碼）本來就存在那裡了！
太棒了！原料齊全，`make` 這才**真正動手執行第一條編譯指令**：執行 `nasm -f elf32 boot.S -o boot.o` ➔ **生出 `boot.o`**。

        * 第四步：回頭完成 `myos.bin`
        現在 `boot.o` 做出來了，`make` 很高興地回到剛剛暫停的地方（第二步）。
既然原料 `boot.o` 已經到手，它接著執行連結指令：
執行 `ld -m elf_i386 ... -o myos.bin boot.o` ➔ **生出 `myos.bin`**。

        * 第五步：最後才執行 `myos.iso`
        搞定 `myos.bin` 之後，總指揮官 `all` 的最後一個目標是 `myos.iso`：
        ```makefile
        myos.iso: myos.bin grub.cfg
        grub-mkrescue ...
        ```
        這行意思是：「**想要做出 `myos.iso`，必須先給我 `myos.bin` 和 `grub.cfg`。**」
因為前面的步驟已經把 `myos.bin` 誕生出來了，`grub.cfg` 也在資料夾裡。原料全部到位！
執行 `grub-mkrescue ...` ➔ **誕生最終的 `myos.iso`**。

**步驟 C：依照建築藍圖進行連結 (Linking)**

```makefile
myos.bin: boot.o
	$(DOCKER_CMD) ld -m elf_i386 -n -T linker.ld -o myos.bin boot.o
```

* **做什麼：** 呼叫 Docker 內的連結器 `ld`，把上一步的 `boot.o` 真正打包成核心二進位檔案 `myos.bin`。
* **關鍵參數：**
    * `-m elf_i386`：再次強調，這是要給 32 位元 x86 處理器跑的核心。
    * `-T linker.ld`：使用指定的檔案`linker.ld`作為連結腳本。它的作用：就是把之前寫的那張「建築藍圖（linker.ld）」餵給連結器。
    * `-n`（NMAGIC）：叫連結器不要對檔案做多餘的頁面記憶體對齊優化，這能大幅縮小底層二進位檔的體積，避免 GRUB 載入時出錯。

* **🔺 NMAGIC的作用為何？**
現代的編譯器和連結器（如 `ld`）預設都是為了編譯「在 Linux 上執行的應用程式（如 Chrome、LINE）」而設計的；但我們現在做的是「直接在裸機上跑的作業系統核心」。這兩者的需求完全不同，這也是為什麼需要 `-n` 這個參數的原因。
**(1) 何謂「多餘的頁面記憶體對齊優化」？**
現代 CPU 與作業系統（如 Linux）在管理記憶體時，不是一個位元組一個位元組管的，而是以 **「頁面（Page）」** 為單位，在 x86 架構上，**一個頁面通常是 4096 位元組（4KB）**。
為了安全，Linux 會對不同的頁面設定權限：
    * `.text`（程式碼）所在的頁面：設定為「可讀、可執行、不可寫入」（防止病毒修改程式碼）。
    * `.data`（變數）所在的頁面：設定為「可讀、可寫入、不可執行」（防止駭客在變數區執行惡意程式）。

    為了讓 Linux 載入程式時可以輕鬆地設定這些權限，連結器預設會進行**頁面對齊優化**：它強迫檔案中的 `.text` 和 `.data` 等區段，**各自都必須從 4KB 的倍數位置開始**。

    **(2) 為何取消這個優化能大幅縮小體積？**

    問題就在於，我們寫的作業系統核心 **太小了**！

    我們印出「OK」的程式碼只有區區幾十個位元組。如果啟用了頁面對齊優化，連結器會怎麼做？

	```text
	【啟用對齊優化時的檔案構造】
	┌──────────────────────────────────────┐
	│ .text 區段 (我們寫的 code，只有 30 bytes) │
	├──────────────────────────────────────┤
	│ 補零 (Padding) 填滿剩下的 4066 bytes    │ ◄── 這些全部都是浪費空間的 0x00！
	├──────────────────────────────────────┤ ◄── 剛好滿 4KB (4096 bytes)
	│ .rodata 區段 (開始於下一個 4KB 邊界)    │
	└──────────────────────────────────────┘
	
	```

    因為程式碼太短，連結器為了湊滿 4KB 的邊界，會在檔案裡**硬塞幾千個完全沒用的 `0x00`（補零，Padding）**。如果你的程式有三個區段，這個檔案就會被撐到 12KB 以上。

    當我們加上 **`-n` (NMAGIC)** 參數後：
連結器就會取消 4KB 頁面對齊，改用最緊湊的方式排版（可能只做 4 位元組或 8 位元組的微小對齊）。程式碼一結束，立刻接下一位，**幾千個位元組的零當場消失**，檔案體積自然從十幾 KB 暴富縮小到只剩幾百個位元組！

    **(3) 為何不取消優化可能導致 GRUB 載入時出錯？**

    這跟 GRUB 的「智商」以及現代連結器的「過度優化」有關：

    * 原因 A：GRUB 的 ELF 載入器非常輕量（陽春）

        GRUB 是一個在開機階段執行的 Bootloader，它的記憶體空間有限，裡面的程式碼非常精簡。它內建的二進位檔案（ELF）解析器，只能處理結構非常單純、老式的執行檔。
現代連結器如果不加 `-n`，除了會補零，還會產生非常複雜的現代優化標頭（例如 `PT_GNU_RELRO` 等段落資訊，用來防範現代黑客攻擊）。GRUB 看到這些複雜的現代排版結構時，往往會因為「看不懂」或無法解析，直接噴出 `Error 13: Invalid or unsupported executable format` 給你看。

    * 原因 B：記憶體對齊的位址衝突

        現代 64 位元系統的連結器，有時候預設的對齊顆粒度不是 4KB，而是恐怖的 **2MB 甚至 4MB（為了支援 Large Pages 大頁面優化）**。
如果連結器擅自把檔案裡的區段挪動、跳過了好幾 MB 的空間，這會導致二進位檔案內部的「虛擬記憶體位址」與「實際檔案偏移量」產生巨大的斷層。當 GRUB 試圖照著藍圖把檔案搬進記憶體時，會發現檔案大小和它預期的對齊位址對不上，就會導致載入失敗或崩潰。

* **🔺總結 `-n NMAGIC` 的功勞**

    加上 `-n`，就是明確地告訴連結器：

    > 「我現在是在寫最底層的 Bare-metal（裸機）核心，不要給我搞現代作業系統那一套複雜的 4KB/2MB 頁面權限隔離。**請用最老式、最簡單、最緊湊的結構幫我打包**！」

    這樣打包出來的核心，結構乾淨溜溜，GRUB 一眼就能看懂，自然就能百分之百安全開機了！

**步驟 D：製作最終的可開機 ISO 光碟映像檔**

```makefile
myos.iso: myos.bin grub.cfg
	mkdir -p isodir/boot/grub
	cp myos.bin isodir/boot/myos.bin
	cp grub.cfg isodir/boot/grub/grub.cfg
	$(DOCKER_CMD) grub-mkrescue -o myos.iso isodir
	rm -rf isodir
```

* **做什麼：**
1. 在本機建立一個臨時的資料夾結構 `isodir/boot/grub`（這是 GRUB 規定的標準 ISO 結構）。
更精確地說，我們可以把 `isodir/boot/grub` 拆成兩個部分來看：
    (1) `isodir`：只是你本機的暫存資料夾名稱（可變）
    在 Makefile 中，`isodir` 只是我們隨便取的一個名字，代表「準備打包成 ISO 的根目錄」。你把它改名叫 `my_temp_folder` 也可以。當打包完成後，這個資料夾就會變成 ISO 光碟檔的**根目錄（`/`）**。
    
    (2) `/boot/grub`：ISO 內部的硬性路徑（不可變）

    這是 GRUB 官方定義死的標準規格。當你執行 `grub-mkrescue` 時，它會強制去你指定的資料夾底下尋找一個特定的檔案：

    > **`根目錄/boot/grub/grub.cfg`**

    這是整個開機流程的靈魂核心。

    (3) 如果不照這個路徑放，會發生什麼事？

    如果你圖方便，把檔案亂放，例如直接放在根目錄：`isodir/grub.cfg`。

    `grub-mkrescue` 依然會幫你做出一片 ISO 光碟，但當你把這片光碟丟進虛擬機（如 QEMU 或 VirtualBox）開機時，會發生以下慘劇：

    *  **畫面上不會出現選單**，也不會自動載入你的作業系統。
    *   電腦會直接停在一個漆黑、冰冷的命令列畫面，顯示：
		```text
		grub> _
		```
    這是因為 GRUB 啟動時，它的程式碼內部已經寫死了：「**我只會去 `/boot/grub/grub.cfg` 這個位置讀取選單藍圖。**」如果這個位置是空的，它就會不知所措，只能把主控台丟給使用者，要求你手動用指令去尋找核心。

    (4) 那核心 `myos.bin` 也要固定放在這裡嗎？

    核心檔案（`myos.bin`）的位置其實**比較自由**。你把它放在 ISO 的根目錄（`/myos.bin`）或放在 `/boot/myos.bin` 都可以。

    不過，通常大家會習慣把它跟 `grub.cfg` 一起放在 `/boot/` 資料夾下，這是一種業界約定俗成的乾淨分類（把開機相關的二進位檔都塞在 boot）。只要你在 `grub.cfg` 裡面寫對它的路徑，GRUB 就找得到它。

3. 把編譯好的核心 `myos.bin` 和開機選單設定檔 `grub.cfg` 丟進去。
4. 呼叫 Docker 內的 `grub-mkrescue`（它在後台會使用 `xorriso`）把這個資料夾結構壓縮、打包成一個真正的 **`myos.iso`**。
5. 把暫存資料夾刪除，保持目錄乾淨。


**步驟 E：打掃戰場（清理檔案）**

```makefile
clean:
	rm -f *.o *.bin *.iso
```

* **做什麼：** 當你輸入 `make clean` 時，它會幫你把所有中間產生的臨時檔（`.o`、`.bin`）以及最終的 `myos.iso` 通通刪掉，讓你可以重新乾淨地編譯一次。

**🔴 總結**

這個 `Makefile` 完美的解決了跨平台開發的痛點。儘管我這邊用的是現代的 64 位元主機，它也能透過 Docker 精準地控制編譯器，捏出一個 32 位元、符合 Multiboot2 規範、可以用虛擬機開機執行的作業系統 ISO 檔！

### Step 6. 執行與驗證
**🔴 編譯核心**： 執行 `make`。這會先建置 Docker image，然後組譯 boot.S，最後連結成 myos.bin。
執行完會整個資料夾會包含這些檔案：
```bash
$ ls
boot.o  boot.S  Dockerfile  grub.cfg 
linker.ld  Makefile  myos.bin  myos.iso
```
**🔴 安裝 QEMU** (如果你還沒裝)： 安裝支援 x86 模擬的 QEMU：
```
sudo apt update
sudo apt install qemu-system-x86
```
**🔴啟動作業系統**： 執行以下指令，讓 QEMU 直接載入你的核心二進位檔：
```bash
qemu-system-i386 -cdrom myos.iso
```
透過這段指令QEMU 會模擬一台真正的電腦，先去讀取光碟裡的 GRUB 開機管理程式。

GRUB 啟動後，會去讀取你的 grub.cfg，並由 GRUB 去解析 myos.bin 裡的 Multiboot2 標頭。

GRUB 成功識別後，就會把控制權交給你的核心。

執行後畫面就會出現：

<img width="717" height="469" alt="image" src="https://github.com/user-attachments/assets/c971421d-d87c-4cc8-ac21-7cafb5966b86" />

<img width="720" height="463" alt="image" src="https://github.com/user-attachments/assets/4be0fa30-4824-45d4-b683-c7043205acdd" />



