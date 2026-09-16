/*
 * pam_macidprobe — diagnostic PAM module.
 *
 * Answers one question before we build anything real:
 *   does macOS actually consult /etc/pam.d/screensaver on an unlock attempt,
 *   and does it reach us when the password field is EMPTY?
 *
 * Default mode is pure logging: it always returns PAM_IGNORE and cannot
 * affect the outcome of an authentication.
 *
 * If (and only if) the module is given the `allow_trigger` argument, it will
 * additionally return PAM_SUCCESS when the trigger file exists AND the
 * submitted password was empty. That is the deliberate phase-2 test of the
 * press-Enter-to-unlock path. Delete the trigger file to disable instantly.
 */

#include <security/pam_appl.h>
#include <security/pam_modules.h>

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <syslog.h>
#include <sys/stat.h>

#define LOGFILE  "/var/tmp/macidprobe.log"
#define TRIGGER  "/var/db/faceid-approve"
#define TRIGGER_TTL 300  /* seconds; a forgotten trigger disarms itself */

static void plog(const char *fmt, ...)
    __attribute__((format(printf, 1, 2)));

static void plog(const char *fmt, ...)
{
	char msg[1024];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);

	/* syslog so `log stream` picks it up even if the file is unwritable */
	syslog(LOG_AUTHPRIV | LOG_NOTICE, "macidprobe: %s", msg);

	FILE *f = fopen(LOGFILE, "a");
	if (f != NULL) {
		char stamp[64];
		time_t now = time(NULL);
		struct tm tm;
		localtime_r(&now, &tm);
		strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);
		fprintf(f, "%s [pid %d uid %d] %s\n", stamp, getpid(), geteuid(), msg);
		fclose(f);
	}
}

static const char *str(const char *s)
{
	return s != NULL ? s : "(null)";
}

PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char *argv[])
{
	const char *service = NULL, *user = NULL, *authtok = NULL, *tty = NULL;
	int allow_trigger = 0;

	for (int i = 0; i < argc; i++)
		if (strcmp(argv[i], "allow_trigger") == 0)
			allow_trigger = 1;

	pam_get_item(pamh, PAM_SERVICE, (const void **)&service);
	pam_get_item(pamh, PAM_AUTHTOK, (const void **)&authtok);
	pam_get_item(pamh, PAM_TTY,     (const void **)&tty);
	pam_get_user(pamh, &user, NULL);

	/* The headline number: authtok_len == 0 means an empty Enter reached PAM. */
	long authtok_len = (authtok != NULL) ? (long)strlen(authtok) : -1;

	plog("authenticate service=%s user=%s tty=%s flags=0x%x "
	     "authtok=%s authtok_len=%ld allow_trigger=%d",
	     str(service), str(user), str(tty), flags,
	     authtok != NULL ? "present" : "NOT_SET", authtok_len, allow_trigger);

	if (allow_trigger && authtok_len <= 0) {
		struct stat st;

		if (stat(TRIGGER, &st) != 0)
			return PAM_IGNORE;

		/*
		 * The trigger file is a skeleton key: while it exists, an empty
		 * Return unlocks the machine. Three guards, because we run as root
		 * and a file any local process can forge would be a lock-screen
		 * bypass, not a feature.
		 */
		if (st.st_uid != 0) {
			plog("--> trigger REJECTED: not owned by root (uid %d)", st.st_uid);
			return PAM_IGNORE;
		}
		if (st.st_mode & (S_IWGRP | S_IWOTH)) {
			plog("--> trigger REJECTED: group/world writable (mode %o)",
			     st.st_mode & 07777);
			return PAM_IGNORE;
		}
		if (time(NULL) - st.st_mtime > TRIGGER_TTL) {
			plog("--> trigger REJECTED: expired (%lds old, ttl %ds)",
			     (long)(time(NULL) - st.st_mtime), TRIGGER_TTL);
			return PAM_IGNORE;
		}

		plog("--> TRIGGER VALID and authtok empty: returning PAM_SUCCESS");
		return PAM_SUCCESS;
	}

	return PAM_IGNORE;
}

PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh __unused, int flags, int argc __unused,
               const char *argv[] __unused)
{
	plog("setcred flags=0x%x", flags);
	return PAM_IGNORE;
}

PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh __unused, int flags, int argc __unused,
                 const char *argv[] __unused)
{
	plog("acct_mgmt flags=0x%x", flags);
	return PAM_IGNORE;
}
