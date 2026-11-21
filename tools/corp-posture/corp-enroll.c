/*
 * corp-enroll.c — automated Secure Boot key enrollment (corp-posture spike)
 *
 * A minimal UEFI application that reads PK.der, KEK.der, db.der from
 * \keys\ on the ESP it booted from and installs them as the platform's
 * PK/KEK/db (replacing whatever was there), then enables Secure Boot.
 * Prints every step; refuses to continue if any file is missing.
 *
 * This is the "our own keys on real hardware" artifact: boot this stick
 * once on any UEFI machine (COM Express module, laptop, Pi with EDK2)
 * and the machine thereafter trusts exactly our CA. Physical presence =
 * choosing to boot the stick; no setup-menu dancing, scriptable on the
 * bench via PiKVM.
 *
 * Build (gnu-efi):
 *   gcc -I/usr/include/efi -I/usr/include/efi/x86_64 -fpic -fshort-wchar
 *       -fno-builtin -fno-stack-protector -shared -Wall -o corp-enroll.so
 *       corp-enroll.c && objcopy -j .text -j .sdata -j .data -j .rodata
 *       -j .dynamic -j .dynsym -j .rel -j .rela -j .reloc
 *       --target=efi-app-x86_64 corp-enroll.so corp-enroll.efi
 */
#include <efi.h>
#include <efilib.h>


static EFI_GUID EFI_GLOBAL = EFI_GLOBAL_VARIABLE;
static EFI_GUID EFI_IMG_INFO = EFI_LOADED_IMAGE_PROTOCOL_GUID;
static EFI_GUID EFI_CUSTOM_MODE =
    { 0xc076ec0c, 0x7028, 0x4399, { 0xa0, 0x72, 0x71, 0xee, 0x5c, 0x44, 0x8b, 0x9f } };
static EFI_GUID EFI_FS_INFO = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;

static void fatal(CHAR16 *m, EFI_STATUS s)
{
	Print(L"corp-enroll: ERROR: %s (rc=0x%lx)\r\n", m, s);
	Print(L"corp-enroll: halting — keys NOT (fully) installed\r\n");
}

static EFI_GUID EFI_SEC_DB =
    { 0xd719b2cb, 0x3d3a, 0x4596, { 0xa3, 0xbc, 0xda, 0xd0, 0x0e, 0x67, 0x65, 0x6f } };

static EFI_STATUS set_var(CHAR16 *name, UINT8 *data, UINTN size)
{
	/* db lives under EFI_IMAGE_SECURITY_DATABASE_GUID; PK/KEK under the
	 * global GUID — SetVariable with the wrong GUID is not routed to the
	 * security-variable policy at all (INVALID_PARAMETER, found 2026-11-21) */
	EFI_GUID *g = (name[0] == L'd' && name[1] == L'b' && !name[2])
	                  ? &EFI_SEC_DB : &EFI_GLOBAL;
	/* EFI_VARIABLE_NON_VOLATILE | BOOTSERVICE | RUNTIME | TIME_BASED */
	/* .auth blobs carry a full EFI_VARIABLE_AUTHENTICATION_2 descriptor
	 * (signed by the corp root over name+guid+attrs+timestamp+payload) —
	 * accepted VERIFIED in user mode against the enrolled PK, and
	 * accepted UNVERIFIED in setup mode (edk2 AuthService: 'If in setup
	 * mode ... no authentication needed'). */
	return uefi_call_wrapper(RT->SetVariable, 5, name, g,
	                         EFI_VARIABLE_NON_VOLATILE |
	                             EFI_VARIABLE_BOOTSERVICE_ACCESS |
	                             EFI_VARIABLE_RUNTIME_ACCESS |
	                             EFI_VARIABLE_TIME_BASED_AUTHENTICATED_WRITE_ACCESS,
	                         size, data);
}

static UINT8 enable_sb[] = { 1 };
static UINT8 custom_off[] = { 0 };
static UINT8 setup_mode[] = { 0 };

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
	EFI_STATUS s;
	EFI_LOADED_IMAGE *li;
	EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs;
	EFI_FILE_PROTOCOL *root, *f;
	UINTN fsz;
	CHAR16 *names[3] = { L"db", L"KEK", L"PK" };
	CHAR16 *vars[3] = { L"db", L"KEK", L"PK" };
	static UINT8 buf[3][262144];
	UINTN sizes[3] = { 0, 0, 0 };
	int i;

	InitializeLib(image, st);
	Print(L"corp-enroll: automated SB key enrollment (corp-posture)\r\n");

	s = uefi_call_wrapper(BS->HandleProtocol, 3, image, &EFI_IMG_INFO,
	                      (void **)&li);
	if (EFI_ERROR(s)) { fatal(L"HandleProtocol", s); return s; }
	s = uefi_call_wrapper(BS->HandleProtocol, 3, li->DeviceHandle,
	                      &EFI_FS_INFO, (void **)&fs);
	if (EFI_ERROR(s)) { fatal(L"no filesystem on boot device", s); return s; }
	s = uefi_call_wrapper(fs->OpenVolume, 2, fs, &root);
	if (EFI_ERROR(s)) { fatal(L"OpenVolume", s); return s; }

	for (i = 0; i < 3; i++) {
		CHAR16 path[64];
		SPrint(path, 64, L"\\keys\\%s.auth", names[i]);
		s = uefi_call_wrapper(root->Open, 5, root, &f, path,
		                      EFI_FILE_MODE_READ, 0);
		if (EFI_ERROR(s)) {
			Print(L"corp-enroll: missing %s — aborting\r\n", path);
			return s;
		}
		fsz = sizeof(buf[i]);
		s = uefi_call_wrapper(f->Read, 3, f, &fsz, buf[i]);
		uefi_call_wrapper(f->Close, 1, f);
		if (EFI_ERROR(s) || fsz == 0 || fsz == sizeof(buf[i])) {
			Print(L"corp-enroll: bad %s (%lu bytes)\r\n", path,
			      (unsigned long)fsz);
			return EFI_BAD_BUFFER_SIZE;
		}
		sizes[i] = fsz;
		Print(L"corp-enroll: read %s (%lu bytes)\r\n", path,
		      (unsigned long)fsz);
	}

	/* order matters: db, KEK, then PK last (PK is the point of no return) */
	for (i = 0; i < 3; i++) {
		s = set_var(vars[i], buf[i], sizes[i]);
		if (EFI_ERROR(s)) { fatal(vars[i], s); return s; }
		Print(L"corp-enroll: installed %s (%lu bytes)\r\n", vars[i],
		      (unsigned long)sizes[i]);
	}
	{
		UINT8 off[] = { 0 };
		s = uefi_call_wrapper(RT->SetVariable, 5, L"CustomMode",
		                      &EFI_CUSTOM_MODE,
		                      EFI_VARIABLE_NON_VOLATILE |
		                          EFI_VARIABLE_BOOTSERVICE_ACCESS |
		                          EFI_VARIABLE_RUNTIME_ACCESS,
		                      1, off);
		if (EFI_ERROR(s)) Print(L"corp-enroll: CustomMode off failed — power-cycle to be safe\r\n");
	}

	Print(L"corp-enroll: DONE — platform now trusts only our CA.\r\n");
	Print(L"corp-enroll: remove this stick and boot the signed image.\r\n");
	return EFI_SUCCESS;
}
