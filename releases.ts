import { execSync } from 'child_process';
import { readFileSync, writeFileSync, appendFileSync, existsSync, unlinkSync } from 'fs';
import { homedir, tmpdir } from 'os';
import { join } from 'path';

const CACHE_FILE = join(homedir(), '.releases_cache.txt');

function exec(cmd: string): string {
    try {
        return execSync(cmd, { encoding: 'utf-8' }).trim();
    } catch {
        return '';
    }
}

function loadCache(): Map<string, { build: string; msg: string }> {
    const cache = new Map<string, { build: string; msg: string }>();
    if (!existsSync(CACHE_FILE)) return cache;

    const lines = readFileSync(CACHE_FILE, 'utf-8').split('\n').filter(Boolean);
    for (const line of lines) {
        const [hash, build, ...msgParts] = line.split('|');
        if (hash) {
            cache.set(hash, { build: build || '', msg: msgParts.join('|') });
        }
    }
    return cache;
}

function releases() {
    const newEntries = join(tmpdir(), `releases_new_${Date.now()}.txt`);

    exec('git fetch --tags --quiet');

    const cache = loadCache();

    const tagsOutput = exec(
        "gh release list --repo miroapp-dev/client --limit 10 --json tagName -q '.[].tagName'",
    );
    const tags = tagsOutput.split('\n').filter(Boolean);

    let prev = '';
    for (const tag of tags) {
        if (prev) {
            console.log(prev);

            const logOutput = exec(`git log --format="%h %s" "${tag}..${prev}"`);
            if (logOutput) {
                for (const line of logOutput.split('\n')) {
                    const spaceIdx = line.indexOf(' ');
                    if (spaceIdx === -1) continue;

                    const hash = line.slice(0, spaceIdx);
                    const rest = line.slice(spaceIdx + 1).replace(/ \(#\d+\)$/, '');

                    const cached = cache.get(hash);
                    if (cached) {
                        const buildPrefix = cached.build ? `${cached.build} ` : '';
                        console.log(`  ${hash} ${buildPrefix}${cached.msg}`);
                    } else {
                        const build =
                            exec(`git tag --points-at "${hash}"`)
                                .split('\n')
                                .find((t) => /^\d+\.\d+\.\d+/.test(t)) || '';

                        const buildPrefix = build ? `${build} ` : '';
                        console.log(`  ${hash} ${buildPrefix}${rest}`);
                        appendFileSync(newEntries, `${hash}|${build}|${rest}\n`);
                    }
                }
            }
            console.log('');
        }
        prev = tag;
    }

    if (prev) {
        console.log(prev);
        console.log('  (oldest in range — no prior release to diff)');
    }

    // Append new entries to cache
    if (existsSync(newEntries)) {
        const content = readFileSync(newEntries, 'utf-8');
        if (content.trim()) {
            if (!existsSync(CACHE_FILE)) writeFileSync(CACHE_FILE, '');
            appendFileSync(CACHE_FILE, content);
        }
        unlinkSync(newEntries);
    }
}

releases();
