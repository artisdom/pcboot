; pcboot MBR.
;
; Searches the boot disk for the pcboot boot volume and launches it via the
; conventional MBR-VBR interface.
;
; The MBR only searches the disk indicated by the DL value.  Other disks could
; conceivably be insecure (e.g. a USB flash drive).
;
; The VBR is identified by the string "PCBOOT" followed by 0xAA55 at the end of
; the VBR.  The MBR searches all partitions, and succeeds if only a single VBR
; is found.  If multiple VBRs match, the MBR aborts.
;
; To avoid a hypothetical(?) DOS vulnerability, the MBR only considers
; partitions whose type ID is one of the expected values for a FAT32 volume.
; (Suppose an attacker could control all of some partition's data.  It could
; create a partition that looked like the boot volume.)  If this risk could be
; ruled out somehow, it could reduce the amount of code here.
;
; TODO:
;  - Improved error checking, such as:
;     - Protecting against infinite loops in the logical partition scanning.
;     - Call the BIOS routine to check for INT13 extensions
;     - If we don't have INT13 extensions, we should avoid scanning partitions
;       past the CHS limit, maybe?
;  - Improve the MBR-VBR interface.  Review the Wikipedia MBR page for details.
;     - Consider passing through DH and DS:DI for some kind of "PnP" data.
;

        bits 16

        extern _stack_end
        extern _mbr
        extern _mbr_unrelocated
        extern _vbr

; Reuse the VBR chain address, 0x7c00, as the buffer
sector_buffer:                  equ _vbr

        section .bss

; Reserve space for global variables.  These variables are not actually
; zero-initialized, but putting them in a section named ".bss" silences nasm
; warnings.

_globals:
disk_number_storage:            resb 1
no_match_yet_storage:           resb 1
match_lba_storage:              resd 1

; BP offsets for global variables  (BP is _globals - 2)

_bp_address:                    equ _globals - 2
disk_number:                    equ disk_number_storage - _bp_address
no_match_yet:                   equ no_match_yet_storage - _bp_address
match_lba:                      equ match_lba_storage - _bp_address


;
; Executable code
;

        section .mbr

        global main
main:
        ; Setup the environment and relocate the code.  Be careful not to
        ; trash DL, which still contains the BIOS boot disk number.
        cli
        xor ax, ax
        mov ss, ax                      ; Clear SS
        mov ds, ax                      ; Clear DS
        mov es, ax                      ; Clear ES
        mov sp, _mbr_unrelocated        ; Set SP to 0x7c00
        mov si, sp
        mov di, _mbr
        mov cx, 512
        cld
        rep movsb                       ; Copy MBR from 0x7c00 to 0x600.
        jmp 0:.relocated                ; Set CS:IP to 0:0x600.

.relocated:
        sti

        ; Use BP to access global variables with smaller memory operands.  We
        ; also use BP as the end address for the primary partition table scan.
        mov bp, _bp_address

        ; GRUB and GRUB2 use DL, but with some kind of adjustment.  Follow the
        ; GRUB2 convention and use DL if it's in the range 0x80-0x8f.
        ; Otherwise, fall back to 0x80.
        mov cl, 0xf0
        and cl, dl
        cmp cl, 0x80
        je .dl_is_plausible
        mov dl, 0x80
.dl_is_plausible:
        mov [bp + disk_number], dl

        ; Search the primary partition table for the pcboot VBR.
        mov byte [bp + no_match_yet], 1
        mov si, mbr_ptable
.primary_scan_loop:
        xor edx, edx
        call scan_pcboot_vbr_partition
        call scan_extended_partition
        add si, 0x10
        cmp si, bp
        jnz .primary_scan_loop

        ; If we didn't find a match, fail at this point.
        cmp byte [bp + no_match_yet], 0
        jne fail

        ; Load the matching sector to 0x7c00 and jump.
        mov esi, [bp + match_lba]
        call read_sector
        xor si, si
        mov dl, [bp + disk_number]
        jmp _vbr




        ; Examine a single partition to see whether it is a matching pcboot
        ; VBR.  If it is one, update the global state (and potentially halt).
        ; Inputs: si points to a partition entry
        ;         edx is a value to add to the entry's LBA
        ; Trashes: esi(high), sector_buffer
scan_pcboot_vbr_partition:
        pusha
        ; Check the partition type.  Allowed types: 0x0b, 0x0c, 0x1b, 0x1c.
        mov al, [si + 4]
        and al, 0xef
        sub al, 0x0b
        cmp al, 1
        ja .done

        ; Look for the appropriate 8-byte signature at the end of the VBR.
        mov esi, [si + 8]
        add esi, edx
        call read_sector
        mov si, sector_buffer + 512 - 8
        mov di, pcboot_vbr_marker
        mov cx, 8
        cld
        repe cmpsb
        jne .done

        ; We found a match!  Abort if this is the second match.
        dec byte [bp + no_match_yet]
        jnz fail
        mov dword [bp + match_lba], esi

.done:
        popa
        ret




        ; Scan a possible extended partition looking for logical pcboot VBRs.
        ; Inputs: si points to a partition entry that might be an EBR
        ; Trashes: esi(high), ecx(high), edx(high), sector_buffer
scan_extended_partition:
        pusha
        mov ecx, [si + 8] ; ecx == start of entire extended partition
        mov edx, ecx      ; edx == start of current EBR

.loop:
        ; At this point:
        ;  - si points at an entry that might be an EBR.  It's either any entry
        ;    in the MBR or the second entry of an EBR.
        ;  - edx is the LBA of the referenced partition.

        ; Check the partition type.  Allowed types: 0x05, 0x0f, 0x85.
        mov al, [si + 4]
        cmp al, 0x0f
        je .match
        and al, 0x7f
        cmp al, 0x05
        jne .done

.match:
        ; si points at an entry for a presumed EBR, whose LBA is in edx.  Read
        ; the EBR from disk.
        mov esi, edx
        call read_sector

        ; Verify that the EBR has the appropriate signature.
        cmp word [sector_buffer + 512 - 2], 0xaa55
        jne .done

        ; Check the first partition for a pcboot VBR.
        mov si, sector_buffer + 512 - 2 - 64
        call scan_pcboot_vbr_partition

        ; Advance to the next EBR.  We must reread the EBR because it was
        ; trashed while scanning for a VBR.
        mov esi, edx
        call read_sector
        mov si, sector_buffer + 512 - 2 - 64 + 16
        mov edx, ecx
        add edx, [si + 8]
        jmp .loop

.done:
        popa
        ret




        ; Inputs: esi: the LBA of the sector to read.
        ; Trashes: none
read_sector:
        pusha
        mov [int13_dap.sect], esi
        mov ah, 0x42
        mov dl, [bp + disk_number]
        mov si, int13_dap
        int 0x13
        jc fail
        popa
        ret




        ; Print a NUL-terminated string and hang.
        ; Inputs: si: the address of the string to print.
fail:
        mov si, pcboot_error
        call print_string
        cli
        hlt




        ; Print a NUL-terminated string.
        ; Inputs: si: the address of the string to print.
        ; Trashes: none
print_string:
        pusha
.loop:
        mov al, [si]
        test al, al
        jz .done
        mov ah, 0x0e
        mov bx, 7
        int 0x10
        inc si
        jmp .loop
.done:
        popa
        ret




;
; Initialized data
;

pcboot_error:
        db "pcboot error",0

pcboot_vbr_marker:
        db "PCBOOT"
        dw 0xaa55

int13_dap:
        db 16                   ; size of DAP structure
        db 0                    ; reserved
        dw 1                    ; sector count
        dw sector_buffer        ; buffer offset
        dw 0                    ; buffer segment
.sect:  dq 0                    ; 64-bit sector LBA

        times 440-($-main) db 0
        dd 0            ; 32-bit disk signature
        dw 0            ; padding
mbr_ptable:
        dd 0, 0, 0, 0
        dd 0, 0, 0, 0
        dd 0, 0, 0, 0
        dd 0, 0, 0, 0
        dw 0xaa55
