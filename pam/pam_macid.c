/*
 * pam_macid — ask the user's macid agent whether the person at the camera is
 * the enrolled one.
 *
 * Installed as:
 *     auth sufficient /opt/macid/lib/pam_macid.so
 * as the first auth line of /etc/pam.d/screensaver_new.
 *
 * Failure policy: this module returns PAM_SUCCESS or PAM_IGNORE, never
 * PAM_AUTH_ERR. Anything that goes wrong — agent down, socket missing, bad
 * ownership, timeout, unrecognized face — falls through to the password stack
 * below. A face unlock that breaks should cost you a password prompt, never
 * your ability to log in.
 */

#include <security/pam_appl.h>
#include <security/pam_modules.h>

#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

#define SOCK_RELPATH "Library/Application Support/MacID/agent.sock"
#define REPLY_TIMEOUT_MS 1500

static int debug_enabled = 0;

static void flog(int priority, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

static void flog(int priority, const char *fmt, ...)
{
	char msg[512];
	va_list ap;

	if (priority == LOG_DEBUG && !debug_enabled)
		return;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);

	syslog(LOG_AUTHPRIV | priority, "pam_macid: %s", msg);
}

/*
 * The socket is the thing that can unlock the machine, so before we trust a
 * word it says: it must live in the target user's own home, and neither it nor
 * its directory may be writable by anyone else. Otherwise another account could
 * plant a socket that always answers OK.
 */
static int path_is_safe(const char *path, uid_t owner)
{
	struct stat st;

	if (lstat(path, &st) != 0) {
		flog(LOG_DEBUG, "lstat(%s): %s", path, strerror(errno));
		return 0;
	}
	if (st.st_uid != owner) {
		flog(LOG_WARNING, "%s owned by uid %d, expected %d — refusing",
		     path, st.st_uid, owner);
		return 0;
	}
	if (st.st_mode & (S_IWGRP | S_IWOTH)) {
		flog(LOG_WARNING, "%s is group/world writable (%o) — refusing",
		     path, st.st_mode & 07777);
		return 0;
	}
	return 1;
}

static int read_with_timeout(int fd, char *buf, size_t len, int timeout_ms)
{
	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	int rc = poll(&pfd, 1, timeout_ms);

	if (rc <= 0)
		return -1;
	return (int)read(fd, buf, len);
}

/*
 * Returns 1 if the agent vouches for this user, 0 otherwise.
 * The agent treats its answer as single-use: asking consumes the token, so a
 * replayed request gets NO.
 */
static int ask_agent(const char *username)
{
	struct passwd *pw = getpwnam(username);
	char sockpath[PATH_MAX], dirpath[PATH_MAX];
	struct sockaddr_un addr;
	char reply[64];
	int fd, n;

	if (pw == NULL) {
		flog(LOG_DEBUG, "unknown user %s", username);
		return 0;
	}

	if (snprintf(sockpath, sizeof(sockpath), "%s/%s", pw->pw_dir, SOCK_RELPATH)
	    >= (int)sizeof(sockpath)) {
		flog(LOG_WARNING, "socket path too long for %s", username);
		return 0;
	}
	snprintf(dirpath, sizeof(dirpath), "%s/Library/Application Support/MacID",
	         pw->pw_dir);

	if (!path_is_safe(dirpath, pw->pw_uid) || !path_is_safe(sockpath, pw->pw_uid))
		return 0;

	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		flog(LOG_DEBUG, "socket(): %s", strerror(errno));
		return 0;
	}

	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strlcpy(addr.sun_path, sockpath, sizeof(addr.sun_path));

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		flog(LOG_DEBUG, "connect(%s): %s — agent not running?",
		     sockpath, strerror(errno));
		close(fd);
		return 0;
	}

	if (write(fd, "VERIFY\n", 7) != 7) {
		flog(LOG_DEBUG, "write(): %s", strerror(errno));
		close(fd);
		return 0;
	}

	memset(reply, 0, sizeof(reply));
	n = read_with_timeout(fd, reply, sizeof(reply) - 1, REPLY_TIMEOUT_MS);
	close(fd);

	if (n <= 0) {
		/* A hung agent must not hang the lock screen. */
		flog(LOG_NOTICE, "no reply within %dms — falling through to password",
		     REPLY_TIMEOUT_MS);
		return 0;
	}

	if (strncmp(reply, "OK", 2) == 0) {
		flog(LOG_NOTICE, "agent vouched for %s", username);
		return 1;
	}

	flog(LOG_DEBUG, "agent declined: %.32s", reply);
	return 0;
}

PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags __unused,
                    int argc, const char *argv[])
{
	const char *user = NULL;
	int i;

	for (i = 0; i < argc; i++)
		if (strcmp(argv[i], "debug") == 0)
			debug_enabled = 1;

	if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
		flog(LOG_DEBUG, "no user in pam handle");
		return PAM_IGNORE;
	}

	if (ask_agent(user))
		return PAM_SUCCESS;

	return PAM_IGNORE;
}

PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh __unused, int flags __unused,
               int argc __unused, const char *argv[] __unused)
{
	return PAM_IGNORE;
}

PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh __unused, int flags __unused,
                 int argc __unused, const char *argv[] __unused)
{
	return PAM_IGNORE;
}
