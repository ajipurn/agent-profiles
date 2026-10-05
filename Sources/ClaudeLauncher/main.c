// `claude` and `claude-profile` for Windows: one small Win32 program that
// CLIProfileManager installs under both names in Claude-Profiles\_cli\bin.
// It needs no Swift runtime, so the copies run on their own, and as real
// .exe files they work from cmd, PowerShell and Git Bash, and from programs
// that start `claude` without a shell, which a .cmd script would not.
//
// claude.exe runs the real claude (the first one on PATH that is not one of
// these shims) as the profile picked in the app: CLAUDE_CONFIG_DIR is set to
// _cli\profiles\<the name in _cli\active>. An explicit CLAUDE_CONFIG_DIR
// always wins, and the Default profile leaves everything untouched (plain
// %USERPROFILE%\.claude). The command line goes on as typed, Ctrl+C is left
// to the real claude, and its exit code comes back.
//
// claude-profile.exe shows, lists or switches that profile from a terminal,
// like the macOS script of the same name.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

// A growing UTF-16 string. A launcher that cannot allocate has nothing
// sensible left to do, so running out of memory ends it.
typedef struct {
    wchar_t *text;
    size_t length;
    size_t capacity;
} Text;

static void textAppend(Text *t, const wchar_t *s, size_t n) {
    if (t->length + n + 1 > t->capacity) {
        size_t capacity = (t->length + n + 1) * 2;
        wchar_t *grown = realloc(t->text, capacity * sizeof *grown);
        if (!grown) ExitProcess(1);
        t->text = grown;
        t->capacity = capacity;
    }
    memcpy(t->text + t->length, s, n * sizeof *s);
    t->length += n;
    t->text[t->length] = L'\0';
}

static void textAdd(Text *t, const wchar_t *s) { textAppend(t, s, wcslen(s)); }

static void textFree(Text *t) {
    free(t->text);
    *t = (Text){0};
}

// Drops the last path component; false when there is none to drop.
static BOOL textCutLastComponent(Text *t) {
    wchar_t *slash = t->text ? wcsrchr(t->text, L'\\') : NULL;
    if (!slash) return FALSE;
    *slash = L'\0';
    t->length = (size_t)(slash - t->text);
    return TRUE;
}

// Console output goes out as UTF-16, redirected output as UTF-8.
static void put(DWORD stream, const wchar_t *s) {
    HANDLE handle = GetStdHandle(stream);
    if (handle == NULL || handle == INVALID_HANDLE_VALUE) return;
    DWORD length = (DWORD)wcslen(s), written, mode;
    if (GetConsoleMode(handle, &mode)) {
        WriteConsoleW(handle, s, length, &written, NULL);
        return;
    }
    int size = WideCharToMultiByte(CP_UTF8, 0, s, (int)length, NULL, 0, NULL, NULL);
    char *utf8 = size > 0 ? malloc((size_t)size) : NULL;
    if (!utf8) return;
    WideCharToMultiByte(CP_UTF8, 0, s, (int)length, utf8, size, NULL, NULL);
    WriteFile(handle, utf8, (DWORD)size, &written, NULL);
    free(utf8);
}

static BOOL isDirectory(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY);
}

static BOOL isFile(const wchar_t *path) {
    DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

static BOOL endsWith(const wchar_t *s, const wchar_t *suffix) {
    size_t length = wcslen(s), suffixLength = wcslen(suffix);
    return length >= suffixLength && _wcsicmp(s + length - suffixLength, suffix) == 0;
}

// This program's own path: ...\Claude-Profiles\_cli\bin\claude.exe.
static BOOL ownPath(Text *path) {
    for (DWORD capacity = MAX_PATH; capacity <= 65536; capacity *= 2) {
        wchar_t *buffer = malloc(capacity * sizeof *buffer);
        if (!buffer) ExitProcess(1);
        DWORD length = GetModuleFileNameW(NULL, buffer, capacity);
        if (length > 0 && length < capacity) textAppend(path, buffer, length);
        free(buffer);
        if (length < capacity) return length > 0;
    }
    return FALSE;
}

// A name the app could have written: no path parts and not only dots, so
// it always names a folder directly inside _cli\profiles.
static BOOL isPlainName(const wchar_t *name) {
    if (!*name || wcspbrk(name, L"\\/:*?\"<>|")) return FALSE;
    for (const wchar_t *c = name; *c; c++) {
        if (*c != L'.') return TRUE;
    }
    return FALSE;
}

static void profileDir(const wchar_t *base, const wchar_t *name, Text *dir) {
    textAdd(dir, base);
    textAdd(dir, L"\\profiles\\");
    textAdd(dir, name);
}

static void activeFile(const wchar_t *base, Text *path) {
    textAdd(path, base);
    textAdd(path, L"\\active");
}

// The first line of _cli\active, UTF-8 like everything the app writes.
static BOOL readActive(const wchar_t *base, Text *name) {
    Text path = {0};
    activeFile(base, &path);
    HANDLE file = CreateFileW(path.text, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    textFree(&path);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    char bytes[1024];
    DWORD count = 0;
    BOOL ok = ReadFile(file, bytes, sizeof bytes, &count, NULL);
    CloseHandle(file);
    if (!ok) return FALSE;

    DWORD start = count >= 3 && memcmp(bytes, "\xEF\xBB\xBF", 3) == 0 ? 3 : 0; // a BOM from Notepad
    DWORD end = start;
    while (end < count && bytes[end] != '\n' && bytes[end] != '\r') end++;
    int length = end > start ? MultiByteToWideChar(CP_UTF8, 0, bytes + start, (int)(end - start), NULL, 0) : 0;
    if (length <= 0) return FALSE;
    wchar_t *wide = malloc((size_t)length * sizeof *wide);
    if (!wide) ExitProcess(1);
    MultiByteToWideChar(CP_UTF8, 0, bytes + start, (int)(end - start), wide, length);
    textAppend(name, wide, (size_t)length);
    free(wide);
    return TRUE;
}

// The profile named in _cli\active, if that name is plain and its folder
// exists; anything else means the Default profile.
static BOOL activeProfile(const wchar_t *base, Text *name) {
    if (!readActive(base, name) || !isPlainName(name->text)) return FALSE;
    Text dir = {0};
    profileDir(base, name->text, &dir);
    BOOL exists = isDirectory(dir.text);
    textFree(&dir);
    return exists;
}

// MARK: - claude.exe

typedef struct {
    DWORD volume, indexHigh, indexLow;
} FileID;

static BOOL fileID(const wchar_t *path, FileID *id) {
    HANDLE file = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                              OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (file == INVALID_HANDLE_VALUE) return FALSE;
    BY_HANDLE_FILE_INFORMATION info;
    BOOL found = GetFileInformationByHandle(file, &info);
    CloseHandle(file);
    if (found) *id = (FileID){info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow};
    return found;
}

// This shim however its path is spelled, or a copy of it under another
// profile folder: starting one from the other would only loop.
static BOOL isShim(const wchar_t *dir, const wchar_t *candidate, const FileID *self) {
    if (endsWith(dir, L"\\Claude-Profiles\\_cli\\bin")) return TRUE;
    FileID id;
    return self && fileID(candidate, &id) && id.volume == self->volume
        && id.indexHigh == self->indexHigh && id.indexLow == self->indexLow;
}

// The first claude on PATH that is not a shim, found the way cmd finds one
// (folder by folder; .exe, then .cmd, then .bat), except never in the
// current folder.
static BOOL findRealClaude(const FileID *self, Text *found) {
    static const wchar_t *const extensions[] = {L".exe", L".cmd", L".bat"};
    DWORD size = GetEnvironmentVariableW(L"PATH", NULL, 0);
    if (size == 0) return FALSE;
    wchar_t *path = malloc(size * sizeof *path);
    if (!path) ExitProcess(1);
    GetEnvironmentVariableW(L"PATH", path, size);

    BOOL result = FALSE;
    for (wchar_t *entry = path, *next; entry && !result; entry = next) {
        wchar_t *separator = wcschr(entry, L';');
        next = separator ? separator + 1 : NULL;
        if (separator) *separator = L'\0';
        // Entries may be quoted, padded with spaces or end in a backslash.
        while (*entry == L' ' || *entry == L'"') entry++;
        size_t length = wcslen(entry);
        while (length > 0 && wcschr(L" \"\\", entry[length - 1])) length--;
        entry[length] = L'\0';
        if (length == 0) continue;

        for (size_t i = 0; i < sizeof extensions / sizeof *extensions && !result; i++) {
            Text candidate = {0};
            textAdd(&candidate, entry);
            textAdd(&candidate, L"\\claude");
            textAdd(&candidate, extensions[i]);
            if (isFile(candidate.text) && !isShim(entry, candidate.text, self)) {
                textAdd(found, candidate.text);
                result = TRUE;
            }
            textFree(&candidate);
        }
    }
    free(path);
    return result;
}

// What follows the program name on this process's command line, untouched:
// the first word is split off the way the C runtime splits argv[0].
static const wchar_t *argumentsAsTyped(void) {
    const wchar_t *p = GetCommandLineW();
    if (*p == L'"') {
        p++;
        while (*p && *p != L'"') p++;
        if (*p) p++;
    } else {
        while (*p && *p != L' ' && *p != L'\t') p++;
    }
    return p;
}

static void addQuoted(Text *command, const wchar_t *path) {
    // Paths can't contain quotes, so nothing inside needs escaping.
    textAdd(command, L"\"");
    textAdd(command, path);
    textAdd(command, L"\"");
}

static void addArguments(Text *command, const wchar_t *arguments) {
    if (*arguments && *arguments != L' ' && *arguments != L'\t') textAdd(command, L" ");
    textAdd(command, arguments);
}

static void commandInterpreter(Text *path) {
    DWORD size = GetEnvironmentVariableW(L"ComSpec", NULL, 0);
    if (size > 1) {
        wchar_t *comspec = malloc(size * sizeof *comspec);
        if (!comspec) ExitProcess(1);
        DWORD length = GetEnvironmentVariableW(L"ComSpec", comspec, size);
        BOOL usable = length > 0 && length < size && isFile(comspec);
        if (usable) textAdd(path, comspec);
        free(comspec);
        if (usable) return;
    }
    wchar_t system[MAX_PATH];
    UINT length = GetSystemDirectoryW(system, MAX_PATH);
    if (length > 0 && length < MAX_PATH) textAppend(path, system, length);
    textAdd(path, L"\\cmd.exe");
}

// Ctrl+C and Ctrl+Break reach the real claude as well, which decides what
// they mean; this process just keeps waiting for it to finish.
static BOOL WINAPI ignoreInterrupt(DWORD event) {
    return event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT;
}

static int runShim(const wchar_t *base, const wchar_t *self) {
    if (GetEnvironmentVariableW(L"CLAUDE_CONFIG_DIR", NULL, 0) <= 1) { // unset or empty
        Text name = {0};
        if (activeProfile(base, &name)) {
            Text dir = {0};
            profileDir(base, name.text, &dir);
            SetEnvironmentVariableW(L"CLAUDE_CONFIG_DIR", dir.text);
            textFree(&dir);
        }
        textFree(&name);
    }

    FileID selfID;
    Text real = {0};
    if (!findRealClaude(fileID(self, &selfID) ? &selfID : NULL, &real)) {
        put(STD_ERROR_HANDLE, L"claude (Agent Profiles shim): real claude not found in PATH\r\n");
        return 127;
    }

    Text application = {0}, command = {0};
    if (endsWith(real.text, L".cmd") || endsWith(real.text, L".bat")) {
        // CreateProcess can't start a batch file by itself; cmd runs it, as
        // it would have if the user had typed the command. /d skips AutoRun
        // and /s keeps the quotes inside the outer pair.
        commandInterpreter(&application);
        addQuoted(&command, application.text);
        textAdd(&command, L" /d /s /c \"");
        addQuoted(&command, real.text);
        addArguments(&command, argumentsAsTyped());
        textAdd(&command, L"\"");
    } else {
        textAdd(&application, real.text);
        addQuoted(&command, real.text);
        addArguments(&command, argumentsAsTyped());
    }

    SetConsoleCtrlHandler(ignoreInterrupt, TRUE);

    // The real claude gets the same console and standard handles.
    STARTUPINFOW startup;
    GetStartupInfoW(&startup);
    PROCESS_INFORMATION process;
    if (!CreateProcessW(application.text, command.text, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL,
                        &startup, &process)) {
        Text message = {0};
        textAdd(&message, L"claude (Agent Profiles shim): could not start ");
        textAdd(&message, real.text);
        textAdd(&message, L"\r\n");
        put(STD_ERROR_HANDLE, message.text);
        return 126;
    }

    // Ending this process (say, a script that times out kills it) ends the
    // real claude too, as it would end a claude started directly. The job
    // holds only that one process: what claude starts is left alone.
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits)
            || !AssignProcessToJobObject(job, process.hProcess)) {
            CloseHandle(job); // best effort: run without it
        }
    }
    ResumeThread(process.hThread);
    CloseHandle(process.hThread);

    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hProcess);
    return (int)code;
}

// MARK: - claude-profile.exe

static void listProfiles(const wchar_t *base, DWORD stream, const wchar_t *indent) {
    Text pattern = {0};
    textAdd(&pattern, base);
    textAdd(&pattern, L"\\profiles\\*");
    WIN32_FIND_DATAW entry;
    HANDLE find = FindFirstFileW(pattern.text, &entry);
    textFree(&pattern);
    if (find == INVALID_HANDLE_VALUE) return;
    do {
        if ((entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && entry.cFileName[0] != L'.') {
            put(stream, indent);
            put(stream, entry.cFileName);
            put(stream, L"\r\n");
        }
    } while (FindNextFileW(find, &entry));
    FindClose(find);
}

// The profile folder's name as it is spelled on disk: folder names don't
// care about case here, but CLIProfileManager compares them exactly.
static BOOL existingProfile(const wchar_t *base, const wchar_t *name, Text *spelled) {
    if (!isPlainName(name)) return FALSE;
    Text dir = {0};
    profileDir(base, name, &dir);
    WIN32_FIND_DATAW entry;
    HANDLE find = FindFirstFileW(dir.text, &entry);
    textFree(&dir);
    if (find == INVALID_HANDLE_VALUE) return FALSE;
    FindClose(find);
    if (!(entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return FALSE;
    textAdd(spelled, entry.cFileName);
    return TRUE;
}

// The format CLIProfileManager writes, the name and a newline, put in
// place in one step.
static BOOL writeActive(const wchar_t *base, const wchar_t *name) {
    int size = WideCharToMultiByte(CP_UTF8, 0, name, -1, NULL, 0, NULL, NULL); // counts the NUL
    if (size <= 1) return FALSE;
    char *bytes = malloc((size_t)size);
    if (!bytes) ExitProcess(1);
    WideCharToMultiByte(CP_UTF8, 0, name, -1, bytes, size, NULL, NULL);
    bytes[size - 1] = '\n';

    Text path = {0}, staged = {0};
    activeFile(base, &path);
    textAdd(&staged, path.text);
    textAdd(&staged, L".new");
    HANDLE file = CreateFileW(staged.text, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    BOOL written = FALSE;
    if (file != INVALID_HANDLE_VALUE) {
        DWORD count = 0;
        written = WriteFile(file, bytes, (DWORD)size, &count, NULL) && count == (DWORD)size;
        CloseHandle(file);
        written = written && MoveFileExW(staged.text, path.text, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
        if (!written) DeleteFileW(staged.text);
    }
    textFree(&staged);
    textFree(&path);
    free(bytes);
    return written;
}

static int runProfileTool(const wchar_t *base) {
    int count = 0;
    wchar_t **arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    const wchar_t *argument = arguments && count > 1 ? arguments[1] : L"";
    Text name = {0};

    if (!*argument) {
        put(STD_OUTPUT_HANDLE, activeProfile(base, &name) ? name.text : L"default");
        put(STD_OUTPUT_HANDLE, L"\r\n");
        return 0;
    }
    // `list` and `help` shadow profiles with those exact names; switch those in the app.
    if (!wcscmp(argument, L"list") || !wcscmp(argument, L"-l") || !wcscmp(argument, L"--list")) {
        put(STD_OUTPUT_HANDLE, L"default\r\n");
        listProfiles(base, STD_OUTPUT_HANDLE, L"");
        return 0;
    }
    if (!wcscmp(argument, L"help") || !wcscmp(argument, L"-h") || !wcscmp(argument, L"--help")) {
        put(STD_OUTPUT_HANDLE,
            L"usage: claude-profile           show the active CLI profile\r\n"
            L"       claude-profile <name>    switch to <name> (new claude runs only)\r\n"
            L"       claude-profile default   back to the plain %USERPROFILE%\\.claude account\r\n"
            L"       claude-profile list      list available profiles\r\n");
        return 0;
    }
    // A real profile folder wins over the `default` keyword.
    if (existingProfile(base, argument, &name)) {
        if (!writeActive(base, name.text)) {
            put(STD_ERROR_HANDLE, L"claude-profile: could not save the active profile\r\n");
            return 1;
        }
        put(STD_OUTPUT_HANDLE, L"CLI profile: ");
        put(STD_OUTPUT_HANDLE, name.text);
        put(STD_OUTPUT_HANDLE, L" — applies to claude commands started from now on\r\n");
        return 0;
    }
    if (!wcscmp(argument, L"default")) {
        Text path = {0};
        activeFile(base, &path);
        if (!DeleteFileW(path.text) && GetLastError() != ERROR_FILE_NOT_FOUND) {
            put(STD_ERROR_HANDLE, L"claude-profile: could not save the active profile\r\n");
            return 1;
        }
        put(STD_OUTPUT_HANDLE,
            L"CLI profile: default (%USERPROFILE%\\.claude) — applies to claude commands started from now on\r\n");
        return 0;
    }
    put(STD_ERROR_HANDLE, L"claude-profile: no profile named '");
    put(STD_ERROR_HANDLE, argument);
    put(STD_ERROR_HANDLE, L"'\r\nprofiles:\r\n  default\r\n");
    listProfiles(base, STD_ERROR_HANDLE, L"  ");
    return 1;
}

int main(void) {
    // ...\_cli\bin\claude.exe: its folder's folder holds everything else.
    Text self = {0}, base = {0};
    if (!ownPath(&self)) return 1;
    textAdd(&base, self.text);
    if (!textCutLastComponent(&base) || !textCutLastComponent(&base)) return 1;
    if (endsWith(self.text, L"\\claude-profile.exe")) return runProfileTool(base.text);
    return runShim(base.text, self.text);
}
