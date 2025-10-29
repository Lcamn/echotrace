//go:build windows
// +build windows

package unlock

import (
	"fmt"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

var (
	kernel32                  = syscall.NewLazyDLL("kernel32.dll")
	ntdll                     = syscall.NewLazyDLL("ntdll.dll")
	procGetCurrentProcess     = kernel32.NewProc("GetCurrentProcess")
	procCloseHandle           = kernel32.NewProc("CloseHandle")
	procDuplicateHandle       = kernel32.NewProc("DuplicateHandle")
	procGetFinalPathNameByHandleW = kernel32.NewProc("GetFinalPathNameByHandleW")
	procNtQuerySystemInformation = ntdll.NewProc("NtQuerySystemInformation")
)

const (
	SystemHandleInformation = 16
	DUPLICATE_SAME_ACCESS   = 0x00000002
	FILE_NAME_NORMALIZED    = 0x0
)

type SYSTEM_HANDLE_TABLE_ENTRY_INFO struct {
	UniqueProcessId       uint16
	CreatorBackTraceIndex uint16
	ObjectTypeIndex       uint8
	HandleAttributes      uint8
	HandleValue           uint16
	Object                uintptr
	GrantedAccess         uint32
}

type SYSTEM_HANDLE_INFORMATION struct {
	NumberOfHandles uint32
	Handles         [1]SYSTEM_HANDLE_TABLE_ENTRY_INFO
}

// CloseSelfFileHandles 关闭当前进程中所有指向指定文件的句柄
func CloseSelfFileHandles(filePath string) error {
	// 规范化文件路径
	absPath, err := filepath.Abs(filePath)
	if err != nil {
		return fmt.Errorf("failed to get absolute path: %w", err)
	}
	absPath = strings.ToLower(strings.ReplaceAll(absPath, "/", "\\"))

	// 获取当前进程句柄
	currentProcess, _, _ := procGetCurrentProcess.Call()
	currentPID := uint32(syscall.Getpid())

	// 查询系统句柄信息
	var bufferSize uint32 = 1024 * 1024 // 1MB 初始缓冲区
	var buffer []byte
	var returnLength uint32

	for {
		buffer = make([]byte, bufferSize)
		ret, _, _ := procNtQuerySystemInformation.Call(
			uintptr(SystemHandleInformation),
			uintptr(unsafe.Pointer(&buffer[0])),
			uintptr(bufferSize),
			uintptr(unsafe.Pointer(&returnLength)),
		)

		if ret == 0 {
			break
		}

		// STATUS_INFO_LENGTH_MISMATCH = 0xC0000004
		if ret == 0xC0000004 {
			bufferSize = returnLength + 1024
			continue
		}

		return fmt.Errorf("NtQuerySystemInformation failed with status: 0x%X", ret)
	}

	// 解析句柄信息
	handleInfo := (*SYSTEM_HANDLE_INFORMATION)(unsafe.Pointer(&buffer[0]))
	numberOfHandles := handleInfo.NumberOfHandles

	closedCount := 0
	handlesPtr := uintptr(unsafe.Pointer(&handleInfo.Handles[0]))

	for i := uint32(0); i < numberOfHandles; i++ {
		handle := (*SYSTEM_HANDLE_TABLE_ENTRY_INFO)(unsafe.Pointer(
			handlesPtr + uintptr(i)*unsafe.Sizeof(SYSTEM_HANDLE_TABLE_ENTRY_INFO{}),
		))

		// 只处理当前进程的句柄
		if uint32(handle.UniqueProcessId) != currentPID {
			continue
		}

		// 复制句柄以便查询路径
		var duplicatedHandle syscall.Handle
		ret, _, _ := procDuplicateHandle.Call(
			currentProcess,
			uintptr(handle.HandleValue),
			currentProcess,
			uintptr(unsafe.Pointer(&duplicatedHandle)),
			0,
			0,
			DUPLICATE_SAME_ACCESS,
		)

		if ret == 0 {
			continue
		}

		// 获取文件路径
		pathBuffer := make([]uint16, 32768)
		ret, _, _ = procGetFinalPathNameByHandleW.Call(
			uintptr(duplicatedHandle),
			uintptr(unsafe.Pointer(&pathBuffer[0])),
			uintptr(len(pathBuffer)),
			FILE_NAME_NORMALIZED,
		)

		// 关闭复制的句柄
		procCloseHandle.Call(uintptr(duplicatedHandle))

		if ret == 0 {
			continue
		}

		// 转换路径
		handlePath := syscall.UTF16ToString(pathBuffer)
		handlePath = strings.ToLower(strings.ReplaceAll(handlePath, "/", "\\"))

		// 移除 \\?\ 前缀
		handlePath = strings.TrimPrefix(handlePath, "\\\\?\\")

		// 检查是否匹配目标文件
		if strings.HasSuffix(handlePath, absPath) || strings.HasSuffix(absPath, handlePath) {
			// 关闭原始句柄
			ret, _, _ := procCloseHandle.Call(uintptr(handle.HandleValue))
			if ret != 0 {
				closedCount++
			}
		}
	}

	if closedCount > 0 {
		return nil
	}

	return fmt.Errorf("no handles found for file: %s", filePath)
}

