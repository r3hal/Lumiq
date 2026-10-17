"""Run on the owner backend over a secure shell; never in build/CI logs."""
import argparse
import asyncio
import json

from .store import Settings, Store
from .google_drive import OwnerGoogleAuthorization


def main():
    parser = argparse.ArgumentParser()
    actions = parser.add_subparsers(dest="action", required=True)
    invite = actions.add_parser("invite")
    invite.add_argument("--label", required=True)
    invite.add_argument("--expires", type=int, default=600)
    invite.add_argument("--recover-device")
    revoke = actions.add_parser("revoke-device")
    revoke.add_argument("device_id")
    actions.add_parser("status")
    actions.add_parser("retry-drive")
    prune = actions.add_parser("prune-completed")
    prune.add_argument("--older-than-days", type=int, default=365)
    discard = actions.add_parser("discard-pending")
    discard.add_argument("device_id")
    discard.add_argument("--confirm-delete-server-staging", action="store_true", required=True)
    actions.add_parser("revoke-drive")
    args = parser.parse_args()
    store = Store(Settings.from_env())
    if args.action == "invite":
        if not OwnerGoogleAuthorization(store).connected:
            raise SystemExit("Authorize owner Google Drive at /admin first")
        code = store.issue_invite(args.label, args.expires, args.recover_device)
        print("One-use invitation (share privately; do not paste in CI or issue logs):")
        print(code)
    elif args.action == "revoke-device":
        store.revoke(args.device_id)
        print("Device authorization revoked; completed Drive backups are preserved.")
    elif args.action == "revoke-drive":
        asyncio.run(OwnerGoogleAuthorization(store).revoke())
        print("Owner Drive authorization revoked. Stored originals and pending work are preserved.")
    elif args.action == "discard-pending":
        # Owner must stop the worker first. Device must be revoked to prevent
        # re-enrollment racing this explicit deletion of server staging only.
        with store.transaction() as db:
            device = db.execute("SELECT revoked FROM devices WHERE id=?", (args.device_id,)).fetchone()
            if not device or not device[0]:
                raise SystemExit("Revoke the device and stop the backend worker first")
            rows = db.execute("SELECT key FROM resources WHERE device_id=? AND state!='complete'", (args.device_id,)).fetchall()
            for row in rows:
                (store.files / (row[0]+".bin")).unlink(missing_ok=True)
            db.execute("DELETE FROM resources WHERE device_id=? AND state!='complete'", (args.device_id,))
        print("Unfinished server staging discarded. Local iPhone and existing Google Drive files were not deleted.")
    elif args.action == "prune-completed":
        import time
        if args.older_than_days < 1:
            raise SystemExit("Keep at least one day of completion receipts")
        with store.transaction() as db:
            db.execute("DELETE FROM resources WHERE state='complete' AND created<?", (time.time()-args.older_than_days*86400,))
        print("Old confirmed receipts pruned. Drive files and iPhone originals are preserved.")
    elif args.action == "retry-drive":
        with store.transaction() as db:
            db.execute("UPDATE resources SET retry_at=0,attempts=0,lease_until=0,state='pendingDrive' WHERE state IN ('failed','pendingDrive','uploadingDrive') AND offset=size")
        print("Eligible complete local resources scheduled for verified Drive retry.")
    else:
        with store.transaction() as db:
            counts = dict(db.execute("SELECT state,COUNT(*) FROM resources GROUP BY state"))
            devices = [dict(row) for row in db.execute("SELECT id,label,revoked FROM devices ORDER BY created")]
        print(json.dumps({"drive_connected": OwnerGoogleAuthorization(store).connected,
                          "resources": counts, "devices": devices}, indent=2))


if __name__ == "__main__":
    main()
