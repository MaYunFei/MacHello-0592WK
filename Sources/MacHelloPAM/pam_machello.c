#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <pwd.h>
#include <security/pam_appl.h>
#include <security/pam_modules.h>

#define PAM_MACHHELLO_VERSION "1.0.0"
#define DEFAULT_AUTH_BIN_1 "/usr/local/bin/machello-auth"
#define DEFAULT_AUTH_BIN_2 "/opt/machello/bin/machello-auth"

static const char *resolve_auth_binary(int argc, const char **argv) {
    // 1. 优先使用 PAM 参数中指定的 bin 路径
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "bin=", 4) == 0) {
            const char *custom_path = argv[i] + 4;
            if (access(custom_path, X_OK) == 0) {
                return custom_path;
            }
        }
    }

    // 2. 检查标准系统安装路径
    if (access(DEFAULT_AUTH_BIN_1, X_OK) == 0) {
        return DEFAULT_AUTH_BIN_1;
    }
    if (access(DEFAULT_AUTH_BIN_2, X_OK) == 0) {
        return DEFAULT_AUTH_BIN_2;
    }

    // 3. 检查用户家目录 ~/.machello/bin/machello-auth
    const char *home = getenv("HOME");
    if (!home) {
        struct passwd *pw = getpwuid(getuid());
        if (pw) home = pw->pw_dir;
    }
    if (home) {
        static char user_bin[1024];
        snprintf(user_bin, sizeof(user_bin), "%s/.machello/bin/machello-auth", home);
        if (access(user_bin, X_OK) == 0) {
            return user_bin;
        }
    }

    return NULL;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)flags;
    const char *username = NULL;
    int retval = pam_get_user(pamh, &username, NULL);
    if (retval != PAM_SUCCESS || !username) {
        return PAM_USER_UNKNOWN;
    }

    const char *auth_bin = resolve_auth_binary(argc, argv);
    if (!auth_bin) {
        // 未找到可执行文件，快速回退到标准密码输入，绝不卡死
        return PAM_AUTH_ERR;
    }

    pid_t pid = fork();
    if (pid < 0) {
        return PAM_AUTH_ERR;
    }

    if (pid == 0) {
        // 子进程执行鉴权程序
        char *const child_argv[] = {
            (char *)auth_bin,
            "--timeout", "2.5",
            NULL
        };
        execv(auth_bin, child_argv);
        _exit(127);
    }

    // 父进程等待子进程鉴权结果
    int status = 0;
    pid_t wpid = waitpid(pid, &status, 0);
    if (wpid == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        return PAM_SUCCESS;
    }

    return PAM_AUTH_ERR;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
