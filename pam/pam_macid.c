/*
 * pam_macid.c
 * Akshith Garapati
 * MacID, face unlock for the macOS lock screen
 *
 * A PAM module that asks the user's MacID agent whether the enrolled face is
 * in front of the camera. Installed as the first line of
 * /etc/pam.d/screensaver_new:
 *
 *     auth sufficient /opt/macid/lib/pam_macid.so
 *
 * When the agent recognises the user it also sends their saved Mac password.
 * The module unlocks the data-protection keychain with it, which loginwindow
 * would otherwise only do with a typed password, then puts it in PAM_AUTHTOK
 * and returns PAM_IGNORE, so the next line, pam_opendirectory use_first_pass,
 * checks it exactly as if it had been typed. A typed password skips MacID.
 *
 * It only ever returns PAM_SUCCESS or PAM_IGNORE, so any failure falls through
 * to the normal password prompt.
 */

#define __STDC_WANT_LIB_EXT1__ 1

#include <security/pam_appl.h>
#include <security/pam_modules.h>

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
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
#define REPLY_TIMEOUT_MS 5000
#define MAX_PASSWORD 512

#ifndef MACID_MODULE_ID
#define MACID_MODULE_ID "unknown"
#endif
/*
 * A hash of this file's source, stamped in at build time. PAM never reads it;
 * the MacID app does, to tell when the installed module is older than the one
 * it ships.
 */
__attribute__((used)) static const char module_id[] = "MACID-MODULE-ID:" MACID_MODULE_ID;

static int debug_enabled = 0;

static void flog(int priority, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

/*
 * flog
 *
 * Writes a printf-style message to the system log under the authpriv facility,
 * prefixed with "pam_macid: ". Debug messages are dropped unless the module
 * was configured with the "debug" argument.
 *
 * priority - the syslog priority, e.g. LOG_DEBUG or LOG_WARNING
 * fmt      - a printf format string, followed by its arguments
 */
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
 * path_is_safe
 *
 * Checks that a path can be trusted to speak for a user before the module
 * talks to it: it must exist, be owned by that user, and not be writable by
 * the group or anyone else. Otherwise another account could plant a socket
 * that always says yes.
 *
 * path  - the file or directory to check
 * owner - the uid that must own it
 *
 * Returns 1 if the path is safe, 0 otherwise.
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

/*
 * read_line_with_timeout
 *
 * Reads one newline-terminated reply, but gives up if it doesn't arrive in
 * time, so a hung agent can never hang the lock screen.
 *
 * fd         - the descriptor to read from
 * buf        - where to store the line, NUL-terminated, newline removed
 * len        - the size of buf
 * timeout_ms - how long to wait for each chunk, in milliseconds
 *
 * Returns the length of the line, or -1 on timeout, error or overflow.
 */
static int read_line_with_timeout(int fd, char *buf, size_t len, int timeout_ms)
{
	size_t used = 0;

	while (used < len - 1) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		char *nl;
		ssize_t n;

		if (poll(&pfd, 1, timeout_ms) <= 0)
			return -1;
		n = read(fd, buf + used, len - 1 - used);
		if (n <= 0)
			break;
		used += (size_t)n;
		buf[used] = '\0';
		if ((nl = strchr(buf, '\n')) != NULL) {
			*nl = '\0';
			return (int)(nl - buf);
		}
	}
	buf[used] = '\0';
	return used > 0 && used < len - 1 ? (int)used : -1;
}

/*
 * hex_decode
 *
 * Decodes the agent's hex-encoded password into out.
 *
 * hex - the hex digits
 * out - where to store the decoded bytes, NUL-terminated
 * len - the size of out
 *
 * Returns 1 on success, 0 if hex is malformed or too long.
 */
static int hex_decode(const char *hex, char *out, size_t len)
{
	size_t n = strlen(hex), i;

	if (n % 2 != 0 || n / 2 >= len)
		return 0;
	for (i = 0; i < n / 2; i++) {
		unsigned int byte;
		if (sscanf(hex + 2 * i, "%2x", &byte) != 1)
			return 0;
		out[i] = (char)byte;
	}
	out[n / 2] = '\0';
	return 1;
}

/*
 * ask_agent
 *
 * Asks the user's MacID agent whether the enrolled face is in front of the
 * camera right now. Finds the agent's socket in the user's home folder, checks
 * that it and its directory are safe, sends VERIFY and waits up to
 * REPLY_TIMEOUT_MS for the answer.
 *
 * username - the user being authenticated
 * password - receives the saved password if the agent sent one, else ""
 * pwlen    - the size of password
 *
 * Returns 1 if the agent answers OK, 0 for any other answer or failure.
 */
static int ask_agent(const char *username, char *password, size_t pwlen)
{
	struct passwd *pw = getpwnam(username);
	char sockpath[PATH_MAX], dirpath[PATH_MAX];
	struct sockaddr_un addr;
	char reply[2 * MAX_PASSWORD + 8];
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

	password[0] = '\0';
	n = read_line_with_timeout(fd, reply, sizeof(reply), REPLY_TIMEOUT_MS);
	close(fd);

	if (n <= 0) {
		flog(LOG_NOTICE, "no reply within %dms — falling through to password",
		     REPLY_TIMEOUT_MS);
		return 0;
	}

	if (strncmp(reply, "OK", 2) == 0) {
		/* Older agents send a bare OK; newer ones append the password. */
		if (reply[2] == ' ' && !hex_decode(reply + 3, password, pwlen))
			password[0] = '\0';
		memset_s(reply, sizeof(reply), 0, sizeof(reply));
		flog(LOG_NOTICE, "agent vouched for %s", username);
		return 1;
	}

	flog(LOG_DEBUG, "agent declined: %.32s", reply);
	return 0;
}

/*
 * unlock_keybag
 *
 * Unlocks the user keybag behind the data-protection keychain with the
 * password. loginwindow does this itself with the typed password, which is
 * empty after a face unlock, and an ordinary app is not allowed to; this
 * module runs inside the lock screen's own process (authorizationhost), which is.
 *
 * password - the user's Mac password
 */
static void unlock_keybag(const char *password)
{
	typedef int (*state_fn)(CFDictionaryRef);
	typedef int (*unlock_fn)(CFDataRef, CFDictionaryRef);
	void *mkb = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag",
	                   RTLD_NOW);
	state_fn state = mkb ? (state_fn)dlsym(mkb, "MKBGetDeviceLockState") : NULL;
	unlock_fn unlock = mkb ? (unlock_fn)dlsym(mkb, "MKBUnlockDevice") : NULL;
	int before = -1, rc = -1, after = -1;

	if (state)
		before = state(NULL);
	if (unlock && before != 0) {
		CFDataRef data = CFDataCreate(NULL, (const UInt8 *)password, (CFIndex)strlen(password));
		if (data) {
			rc = unlock(data, NULL);
			CFRelease(data);
		}
	}
	if (state)
		after = state(NULL);

	flog(LOG_NOTICE, "keybag %d -> %d (unlock %d)", before, after, rc);
}

/*
 * pam_sm_authenticate
 *
 * The entry point PAM calls when the lock screen authenticates. Turns on debug
 * logging if the "debug" argument was given, finds the user, and asks the
 * MacID agent whether they are at the camera.
 *
 * pamh  - the PAM handle for this authentication
 * flags - PAM flags (unused)
 * argc  - the number of module arguments
 * argv  - the module arguments from the stack line
 *
 * Returns PAM_IGNORE with PAM_AUTHTOK set to the saved password when the agent
 * vouches and sends it, so the password check that follows decides and unlocks
 * the keychain; PAM_SUCCESS for an agent that vouches without a password; and
 * PAM_IGNORE otherwise, so the rest of the stack (the password check) decides.
 */
PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags __unused,
                    int argc, const char *argv[])
{
	const char *user = NULL;
	const void *typed = NULL;
	char password[MAX_PASSWORD];
	int i, rc;

	for (i = 0; i < argc; i++)
		if (strcmp(argv[i], "debug") == 0)
			debug_enabled = 1;

	if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
		flog(LOG_DEBUG, "no user in pam handle");
		return PAM_IGNORE;
	}

	/* A typed password goes straight to the password check. */
	if (pam_get_item(pamh, PAM_AUTHTOK, &typed) == PAM_SUCCESS
	    && typed != NULL && ((const char *)typed)[0] != '\0') {
		flog(LOG_DEBUG, "password typed, leaving it to the password check");
		return PAM_IGNORE;
	}

	if (!ask_agent(user, password, sizeof(password)))
		return PAM_IGNORE;

	if (password[0] == '\0')
		return PAM_SUCCESS;

	unlock_keybag(password);
	rc = pam_set_item(pamh, PAM_AUTHTOK, password);
	memset_s(password, sizeof(password), 0, sizeof(password));
	if (rc != PAM_SUCCESS) {
		flog(LOG_WARNING, "could not set PAM_AUTHTOK: %s", pam_strerror(pamh, rc));
		return PAM_SUCCESS;
	}
	return PAM_IGNORE;
}

/*
 * pam_sm_setcred
 *
 * Required by PAM. MacID sets no credentials.
 *
 * Returns PAM_IGNORE.
 */
PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh __unused, int flags __unused,
               int argc __unused, const char *argv[] __unused)
{
	return PAM_IGNORE;
}

/*
 * pam_sm_acct_mgmt
 *
 * Required by PAM. MacID makes no account decisions.
 *
 * Returns PAM_IGNORE.
 */
PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh __unused, int flags __unused,
                 int argc __unused, const char *argv[] __unused)
{
	return PAM_IGNORE;
}
