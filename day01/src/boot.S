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


