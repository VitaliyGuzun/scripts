#!/usr/bin/env ts-node

import { execSync } from 'child_process';

const GREEN = '\x1b[32m';
const RED = '\x1b[31m';
const YELLOW = '\x1b[33m';
const CYAN = '\x1b[36m';
const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';
const RESET = '\x1b[0m';

function gh(args: string): string {
  return execSync(`gh ${args}`, {
    encoding: 'utf-8',
    maxBuffer: 10 * 1024 * 1024,
  }).trim();
}

function graphql(query: string): any {
  const escaped = query.replace(/'/g, "'\\''");
  const raw = execSync(`gh api graphql -f query='${escaped}'`, {
    encoding: 'utf-8',
    maxBuffer: 10 * 1024 * 1024,
  });
  return JSON.parse(raw);
}

function section(title: string) {
  console.log(`\n${BOLD}━━━ ${title} ━━━${RESET}`);
}

async function main() {
  // Detect current PR
  const prArg = process.argv[2];
  let prNumber: number;
  let owner: string;
  let repo: string;

  if (prArg) {
    // Could be a number or URL
    const urlMatch = prArg.match(/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
    if (urlMatch) {
      owner = urlMatch[1];
      repo = urlMatch[2];
      prNumber = parseInt(urlMatch[3], 10);
    } else {
      prNumber = parseInt(prArg, 10);
      const repoInfo = JSON.parse(gh('repo view --json owner,name'));
      owner = repoInfo.owner.login;
      repo = repoInfo.name;
    }
  } else {
    // Use current branch PR
    const prJson = JSON.parse(
      gh('pr view --json number,url,headRefName,baseRefName'),
    );
    prNumber = prJson.number;
    const repoInfo = JSON.parse(gh('repo view --json owner,name'));
    owner = repoInfo.owner.login;
    repo = repoInfo.name;
  }

  const data = graphql(`
		query {
			repository(owner: "${owner}", name: "${repo}") {
				pullRequest(number: ${prNumber}) {
					title
					url
					state
					mergeable
					mergeStateStatus
					reviewDecision
					baseRefName
					headRefName
					commits(last: 1) {
						nodes {
							commit {
								statusCheckRollup {
									contexts(last: 100) {
										nodes {
											... on CheckRun {
												__typename
												name
												conclusion
												status
												detailsUrl
											}
											... on StatusContext {
												__typename
												context
												state
												targetUrl
											}
										}
									}
								}
							}
						}
					}
					reviewRequests(last: 20) {
						nodes {
							requestedReviewer {
								... on Team { name slug }
								... on User { login }
							}
						}
					}
					latestReviews(last: 50) {
						nodes {
							state
							author { login }
						}
					}
					comments(last: 30) {
						nodes {
							author { login }
							body
							url
							createdAt
						}
					}
					reviewThreads(last: 50) {
						nodes {
							isResolved
							comments(first: 100) {
								nodes {
									author { login }
									body
									url
									createdAt
									path
									line
								}
							}
						}
					}
				}
			}
		}
	`);

  const pr = data.data.repository.pullRequest;

  console.log(`\n${DIM}${pr.title}${RESET}`);
  console.log(`${DIM}${pr.headRefName} → ${pr.baseRefName}${RESET}`);
  console.log(`Github: ${DIM}${pr.url}${RESET}`);

  const jiraMatch = pr.headRefName.match(/^([A-Z]+-\d+)/);
  if (jiraMatch) {
    console.log(
      `Jira: ${DIM}https://miro.atlassian.net/browse/${jiraMatch[1]}${RESET}`,
    );
  }

  // ── CI/CD ──
  section('CI/CD');

  const checks =
    pr.commits?.nodes?.[0]?.commit?.statusCheckRollup?.contexts?.nodes ?? [];
  const failed: { name: string; url: string }[] = [];

  for (const check of checks) {
    if (check.__typename === 'CheckRun') {
      if (
        check.conclusion === 'FAILURE' ||
        check.conclusion === 'TIMED_OUT' ||
        check.conclusion === 'CANCELLED'
      ) {
        failed.push({ name: check.name, url: check.detailsUrl });
      }
    } else if (check.__typename === 'StatusContext') {
      if (check.state === 'FAILURE' || check.state === 'ERROR') {
        failed.push({ name: check.context, url: check.targetUrl });
      }
    }
  }

  const pending = checks.filter(
    (c: any) =>
      (c.__typename === 'CheckRun' && c.status === 'IN_PROGRESS') ||
      (c.__typename === 'CheckRun' && c.status === 'QUEUED') ||
      (c.__typename === 'StatusContext' && c.state === 'PENDING'),
  );

  if (failed.length === 0) {
    if (pending.length > 0) {
      console.log(
        `✅ No failures ${DIM}(${pending.length} still running)${RESET}`,
      );
    } else {
      console.log(`✅ CI/CD is fine`);
    }
  } else {
    console.log(`${RED}${failed.length} failed:${RESET}`);
    for (const f of failed) {
      if (f.name !== 'Test E2E / E2E results') {
        console.log(`  ${RED}✗${RESET} ${f.name}`);
        console.log(`    ${DIM}${f.url}${RESET}`);
      }
    }
    if (pending.length > 0) {
      console.log(`${YELLOW}  + ${pending.length} still running${RESET}`);
    }
  }

  // ── Comments ──
  section('Comments');

  const issueComments = (pr.comments?.nodes ?? []).map((c: any) => ({
    author: c.author?.login ?? 'unknown',
    body: c.body,
    url: c.url,
    createdAt: c.createdAt,
    type: 'comment' as const,
  }));

  const reviewThreads = (pr.reviewThreads?.nodes ?? [])
    .filter((t: any) => t.comments.nodes.length > 0)
    .map((t: any) => ({
      comments: t.comments.nodes.map((c: any) => ({
        author: c.author?.login ?? 'unknown',
        body: c.body,
        url: c.url,
        createdAt: c.createdAt,
      })),
      path: t.comments.nodes[0].path,
      line: t.comments.nodes[0].line,
      resolved: t.isResolved,
    }))
    .sort(
      (a: any, b: any) =>
        new Date(a.comments[0].createdAt).getTime() -
        new Date(b.comments[0].createdAt).getTime(),
    );

  const totalComments =
    issueComments.length +
    reviewThreads.reduce((sum: number, t: any) => sum + t.comments.length, 0);

  if (issueComments.length === 0 && reviewThreads.length === 0) {
    console.log(`${DIM}No comments${RESET}`);
  } else {
    console.log(`${totalComments} total comment(s):`);

    // Show issue comments
    for (const c of issueComments) {
      const date = new Date(c.createdAt).toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
      });
      const preview = c.body.split('\n')[0].slice(0, 100);
      console.log(`  ${CYAN}@${c.author}${RESET} ${DIM}${date}${RESET}`);
      console.log(`    ${preview}${c.body.length > 100 ? '…' : ''}`);
      console.log(`    ${DIM}${c.url}${RESET}`);
    }

    // Show review threads
    for (const thread of reviewThreads) {
      const location = thread.path
        ? `${DIM}${thread.path}${thread.line ? `:${thread.line}` : ''}${RESET} `
        : '';
      const replyCount = thread.comments.length - 1;
      const statusIcon = thread.resolved
        ? `${GREEN}✓${RESET}`
        : `${YELLOW}●${RESET}`;
      const firstComment = thread.comments[0];
      const date = new Date(firstComment.createdAt).toLocaleDateString(
        'en-US',
        { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' },
      );
      const preview = firstComment.body.split('\n')[0].slice(0, 100);

      if (thread.resolved) {
        // Compact format for resolved threads
        console.log(
          ` ✅ ${CYAN}@${firstComment.author}${RESET} ${DIM}${date}${RESET} ${DIM} ${replyCount} ${replyCount === 1 ? 'reply' : 'replies'}${RESET}`,
        );
        console.log(
          `    ${location}${preview}${firstComment.body.length > 100 ? '…' : ''}`,
        );
        console.log(`    ${DIM}${thread.comments[0].url}${RESET}`);
      } else {
        // Full format for unresolved threads
        for (let i = 0; i < thread.comments.length; i++) {
          const c = thread.comments[i];
          const date = new Date(c.createdAt).toLocaleDateString('en-US', {
            month: 'short',
            day: 'numeric',
            hour: '2-digit',
            minute: '2-digit',
          });
          const preview = c.body.split('\n')[0].slice(0, 100);
          const isReply = i > 0;
          const prefix = isReply ? '    ↳ ' : '  ';

          if (i === 0) {
            console.log(
              `${prefix}${statusIcon} ${CYAN}@${c.author}${RESET} ${DIM}${date}${RESET} ${DIM}☐ ${replyCount} ${replyCount === 1 ? 'reply' : 'replies'}${RESET}`,
            );
            console.log(
              `  ${prefix}${location}${preview}${c.body.length > 100 ? '…' : ''}`,
            );
          } else {
            console.log(
              `${prefix}${CYAN}@${c.author}${RESET} ${DIM}${date}${RESET}`,
            );
            console.log(
              `  ${prefix}${preview}${c.body.length > 100 ? '…' : ''}`,
            );
          }
        }
        console.log(`  ${DIM}${thread.comments[0].url}${RESET}`);
      }
    }
  }

  // ── Merge Status ──
  section('Merge Status');

  const reasons: string[] = [];

  // Conflicts
  if (pr.mergeable === 'CONFLICTING') {
    reasons.push(`${RED}✗ Has merge conflicts with ${pr.baseRefName}${RESET}`);
  } else if (pr.mergeable === 'UNKNOWN') {
    reasons.push(
      `${YELLOW}? Merge conflict status unknown (still calculating)${RESET}`,
    );
  }

  // Reviews
  if (pr.reviewDecision === 'REVIEW_REQUIRED') {
    const pendingReviewers = (pr.reviewRequests?.nodes ?? []).map((r: any) => {
      const reviewer = r.requestedReviewer;
      return reviewer.slug ? `team/${reviewer.slug}` : reviewer.login;
    });
    let msg = `${RED}✗ Review required${RESET}`;
    if (pendingReviewers.length > 0) {
      msg += `\n    Waiting on: ${pendingReviewers.map((r: string) => `${YELLOW}${r}${RESET}`).join(', ')}`;
    }
    reasons.push(msg);
  } else if (pr.reviewDecision === 'CHANGES_REQUESTED') {
    const changesFrom = (pr.latestReviews?.nodes ?? [])
      .filter((r: any) => r.state === 'CHANGES_REQUESTED')
      .map((r: any) => r.author?.login ?? 'unknown');
    reasons.push(
      `${RED}✗ Changes requested by: ${changesFrom.join(', ')}${RESET}`,
    );
  }

  // CI failures
  if (failed.length > 0) {
    reasons.push(`${RED}✗ ${failed.length} CI check(s) failed${RESET}`);
  }

  // Overall
  if (pr.mergeStateStatus === 'BEHIND') {
    reasons.push(
      `${YELLOW}⚠ Branch is behind ${pr.baseRefName} — needs rebase/merge${RESET}`,
    );
  }

  if (reasons.length === 0 && pr.mergeStateStatus === 'CLEAN') {
    console.log(`${GREEN}✅ Ready to merge${RESET}`);
  } else if (reasons.length === 0 && pr.mergeStateStatus === 'UNSTABLE') {
    console.log(
      `${YELLOW}⚠ Unstable — some non-required checks failed but can merge${RESET}`,
    );
  } else if (reasons.length === 0) {
    console.log(`${YELLOW}Status: ${pr.mergeStateStatus}${RESET}`);
  } else {
    console.log(`${RED}Cannot merge:${RESET}`);
    for (const r of reasons) {
      console.log(`  ${r}`);
    }
  }

  // ── Conflicts detail ──
  if (pr.mergeable === 'CONFLICTING') {
    section('Conflicts');
    console.log(`${RED}This PR has conflicts with ${pr.baseRefName}.${RESET}`);
    console.log(
      `${DIM}Rebase or merge ${pr.baseRefName} into your branch to resolve.${RESET}`,
    );
  }
}

main().catch((err) => {
  console.error(`${RED}Error:${RESET}`, err.message);
  process.exit(1);
});
