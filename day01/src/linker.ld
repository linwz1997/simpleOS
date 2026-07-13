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


