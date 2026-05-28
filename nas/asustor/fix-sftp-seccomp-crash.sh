#!/bin/sh
# SUPERSEDED — see patch-sshd-session.py for the real fix.
#
# Why the earlier versions of this script were misdirections:
#
#  v1: Created /var/log/lastlog + disabled PrintLastLog.
#  v2: Created wtmp/btmp/faillog + made pam_google_authenticator optional.
#  v3: Disabled PAM entirely for the SFTP service.
#  v4: Replaced /usr/builtin/sbin/ipblockman with a no-op shim.
#
# All four reduced the *surface symptoms* (specific files the failed-auth
# cleanup code touched) but did NOT eliminate the SIGSYS kills. Every
# connection from a user not in `administrators` UNIX group was getting
# downgraded to NOUSER by the access-control check, then failing
# authentication, then the cleanup-on-failed-auth path called unlink()
# on something the seccomp filter doesn't allow, and the kernel killed
# the preauth child.
#
# The actual root cause: Asustor patched OpenSSH's sshd-session with a
# hardcoded `DefaultAllowGroups = "administrators"`. The string is at
# file offset 551273 in /usr/bin/sshd-session on ADM 4.2.5+ builds.
# Any user not in administrators UNIX group is rejected at the
# AllowGroups check, regardless of what AllowGroups/AllowUsers is set
# in sshd_config_sftp. The seccomp kills are the visible *consequence*
# of a connection that should never have reached the auth-failure
# cleanup path in the first place.
#
# Use patch-sshd-session.py instead. It surgically replaces the
# hardcoded "administrators" with "users" (padded with nulls to keep
# the same 15-byte slot — no offset shift, no binary corruption),
# letting any user with primary GID 100 (users) authenticate without
# being granted sudo/ADM admin role via UNIX administrators membership.

echo "This script is superseded by patch-sshd-session.py"
echo "See the README + git history for the full root-cause writeup."
exit 1
