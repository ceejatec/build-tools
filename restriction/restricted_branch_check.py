#!/usr/bin/env python3

import argparse
import base64
import os
import sys
import urllib

from jira_util import connect_jira, get_tickets
from importmonkey import add_path
add_path("../build-from-manifest")
from manifest_util import scan_manifests

"""
Intended to run as a Gerrit trigger. The following environment variables
must be set as Gerrit plugin would:
  GERRIT_PROJECT   GERRIT_BRANCH   GERRIT_CHANGE_COMMIT_MESSAGE
  GERRIT_CHANGE_URL   GERRIT_PATCHSET_NUMBER  GERRIT_EVENT_TYPE
"""
PROJECT = os.environ["GERRIT_PROJECT"]
BRANCH = os.environ["GERRIT_BRANCH"]
COMMIT_MSG = base64.b64decode(
    os.environ["GERRIT_CHANGE_COMMIT_MESSAGE"]).decode("utf-8")

# Values for outputting in HTML template (initialized with current globals)
OUTPUT = globals().copy()

# Name for output HTML file
html_filename = "restricted.html"


def check_branch_in_manifest(meta):
    """
    Returns true if the PRODUCT/BRANCH are listed in the named manifest
    """
    print(f"Checking manifest {meta['manifest_path']}")
    manifest_et = meta["_manifest"]
    project_et = manifest_et.find("./project[@name='{}']".format(PROJECT))
    if project_et is None:
        project_et = manifest_et.find("./extend-project[@name='{}']".format(PROJECT))
        if project_et is None:
            print("project {} not found".format(PROJECT))
            return False

    # Compute the default branch for the manifest
    default_branch = "master"
    default_et = manifest_et.find("./default")
    if default_et is not None:
        default_branch = default_et.get("branch", "master")

    # Pull out the branch for the given project
    project_branch = project_et.get("revision", default_branch)
    if project_branch != BRANCH:
        print("project {} on branch {}, not {}".format(
            PROJECT, project_branch, BRANCH)
        )
        return False
    return True


def can_bypass_restriction(ticket, jira):
    """
    Given a Jira ticket ID, returns true if 'doc-change-only' and/or
    'test-change-only' labels are present, or false if neither are
    found
    """
    bypass_labels = [
        'doc-change-only',
        'test-change-only',
        'analytics-compat-jars'
    ]
    try:
        jira_ticket = jira.issue(ticket)
        return any(label in bypass_labels for label in jira_ticket.raw['fields']['labels'])
    except:
        # If the above jira call failed, it was most likely due to the
        # message naming a non-existent ticket eg. due to a typo or
        # similar. We don't want to fail with an error about retrieving
        # labels; just assume the non-existent ticket didn't have any of
        # the approved labels.
        return False


def get_approved_tickets(approval_ticket, jira):
    """
    Given a Jira approval ticket ID, return all linked ticket IDs
    """
    jira_ticket = jira.issue(approval_ticket)
    depends = [
        link.outwardIssue.key for link in jira_ticket.fields.issuelinks
        if hasattr(link, "outwardIssue")
    ]
    relates = [
        link.inwardIssue.key for link in jira_ticket.fields.issuelinks
        if hasattr(link, "inwardIssue")
    ]
    subtasks = [subtask.key for subtask in jira_ticket.fields.subtasks]
    return depends + relates + subtasks + [approval_ticket]


def validate_change_in_ticket(meta):
    """
    Checks the commit message for a ticket name, and verifies it with the the
    approval ticket for the restricted manifest
    """
    approval_ticket = meta.get("approval_ticket")
    global COMMIT_MSG
    # We require a ticket to be named either on the first line of the
    # commit message OR in an Ext-ref: footer line. For the time being
    # we don't enforce footers being at the end of the commit message;
    # any line that starts with Ext-ref: will do.
    msg_lines = ""
    for i, line in enumerate(COMMIT_MSG.split('\n')):
        if i == 0 or line.startswith("Ext-ref:"):
            msg_lines += f"{line}\n"
    fix_tickets = get_tickets(msg_lines)
    if len(fix_tickets) == 0:
        OUTPUT["REASON"] = "the commit message does not name a ticket"
        return False

    # Now get list of approved tickets from approval ticket, and ensure
    # all "fixed" tickets are approved.
    jira = connect_jira()
    approved_tickets = get_approved_tickets(approval_ticket, jira)
    for tick in fix_tickets:
        if tick not in approved_tickets and not can_bypass_restriction(tick, jira):
            # Ok, this fixed ticket isn't approved in approval ticket
            # nor does it contain a label for bypassing this check.
            # Populate the OUTPUT map for the HTML and email templates.
            OUTPUT["REASON"] = "ticket {} is not approved for {} " \
                "(see approval ticket {})".format(
                    tick, meta.get("release_name"), approval_ticket
            )
            return False
    return True


def output_report(meta):
    """
    Outputs report explaining why change was restricted, and exits
    with non-0 return value
    """
    OUTPUT["RELEASE_NAME"] = meta.get("release_name")
    OUTPUT["APPROVAL_TICKET"] = meta.get("approval_ticket")
    OUTPUT.update(os.environ)
    # Specialized mailto: URL for new branch request
    tmpldir = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(tmpldir, "mailto_url.tmpl")) as tmplfile:
        mailto_url = tmplfile.read().strip().format(**OUTPUT)
        print(mailto_url)
        OUTPUT["MAILTO_URL"] = urllib.parse.quote(mailto_url, ":@=&?")
    with open(html_filename, "w") as html:
        with open(os.path.join(tmpldir, "restricted.html.tmpl")) as tmplfile:
            tmpl = tmplfile.read()
        html.write(tmpl.format(**OUTPUT))
        print("\n\n\n*********\nRESTRICTED: {}\n*********\n\n\n".format(
            OUTPUT["REASON"]
        ))
        sys.exit(5)


def failed_output_page(exc_message):
    """
    Outputs page that gives the reason the program unexpectedly exited,
    and exits with a non-0 return value
    """
    tmpldir = os.path.dirname(os.path.abspath(__file__))
    with open(html_filename, "w") as html:
        with open(os.path.join(tmpldir, "rest_failed.html.tmpl")) as tmplfile:
            tmpl = tmplfile.read()
        html.write(tmpl.format(EXC_MESSAGE=exc_message))
        print("\n\n\n*******\nFAILURE: {}\n*******\n\n\n".format(
            exc_message
        ))
        sys.exit(6)


def real_main():
    # Command-line args
    parser = argparse.ArgumentParser()
    parser.add_argument("-p", "--manifest-project", type=str,
                        default="ssh://git@github.com/couchbase/manifest",
                        help="Alternate Git project for manifest")
    args = parser.parse_args()
    manifest_project = args.manifest_project
    # Clean out report file
    if os.path.exists(html_filename):
        os.remove(html_filename)

    # Collect all restricted manifests that reference this branch
    manifests = scan_manifests(manifest_project)
    restricted_manifests = []
    for manifest in manifests:
        meta = manifests[manifest]
        if meta.get("restricted"):
            approval_ticket = meta.get("approval_ticket")
            if approval_ticket is None:
                print("no approval ticket for restricted manifest {}".format(
                    manifest
                ))
                continue

            # Also see if projects are specifically excluded from check for this manifest
            unrestricted_projects = meta.get("unrestricted_projects", [])
            if PROJECT in unrestricted_projects:
                print("Project {} is unrestricted in manifest {}".format(
                    PROJECT, manifest
                ))
                continue

            if not check_branch_in_manifest(meta):
                continue

            # Ok, this proposal is to a branch in a restricted manifest
            restricted_manifests.append(manifest)
            print("Project: {} Branch: {} is in restricted manifest: "
                  "{}".format(PROJECT, BRANCH, manifest))

    # Now *remove* any restricted manifests that are the parent of any other
    # restricted manifests in the list. Logic: if a change is approved for a
    # branch manifest B, it is implicitly approved for its parent A.
    # Conversely, even if it's approved for A, it cannot go into B. Therefore
    # we don't care whether it's approved for A or not.
    restricted_children = list(restricted_manifests)
    for manifest in restricted_manifests:
        print("....looking at {}".format(manifest))
        parent = manifests[manifest].get("parent")
        print("....parent is {}".format(parent))
        if parent in restricted_children:
            print("Not checking manifest {} because it is a parent "
                  "of {}".format(parent, manifest))
            restricted_children.remove(parent)

    # Now, iterate through all restricted manifests that we have left,
    # and ensure this ticket is approved for each.
    for manifest in restricted_children:
        if not validate_change_in_ticket(manifests[manifest]):
            OUTPUT["MANIFEST"] = manifest
            output_report(manifests[manifest])

    # If we get here, the change is allowed!
    # Output "all clear" message if no restricted branches were checked,
    # or if they were checked and approved.
    if restricted_manifests:
        print("\n\n\n*********\nAPPROVED: Commit is approved for all "
              "restricted manifests\n*********\n\n\n")
    else:
        # This is the common case where the change was not to any restricted
        # branches. Normally we want Jenkins to skip voting entirely in this
        # case, to prevent excessive Gerrit comment spam. We indicate this by
        # outputting the word "SILENT". However, if this check was triggered
        # by an explicit "check approval" Gerrit comment, we need to ensure
        # it is not silent in any case.
        silent = " (SILENT)"
        if os.environ.get("GERRIT_EVENT_TYPE") == "comment-added":
            silent = ""
        print("\n\n\n*********\nUNRESTRICTED{}: Branch is in no restricted "
              "manifests\n*********\n\n\n".format(silent))

def main():
    # This is a MAJOR hack right now to try to ensure something
    # is usefully printed by the program even if an unexpected
    # exception occurs; further refinement should check for
    # specific exceptions and handle appropriately as needed
    try:
        real_main()
    except Exception as exc:
        failed_output_page(sys.exc_info()[1])
