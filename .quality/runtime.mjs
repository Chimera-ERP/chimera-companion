// Canonical quality runtime. Copies in sibling repositories are generated.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { match } from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync, spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const excluded = new Set(['.git', 'node_modules', 'dist', 'build', '.dart_tool', '.next', '.runtime', '.tmp', '.quality-receipts', 'coverage', 'dev-dist', '.pub-cache']);

const hash = value => crypto.createHash('sha256').update(value).digest('hex');

const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));

const git = (root, args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });

export function sourceFiles(root, directory = '') {
  if (!directory) {
    try {
      return [...new Set(git(root, ['ls-files', '--cached', '--others', '--exclude-standard', '-z']).split('\0').filter(Boolean))]
        .filter(file => !file.split('/').some(part => excluded.has(part)))
        .filter(file => !file.startsWith('tests/e2e/artifacts/') && !file.startsWith('docs/ui-ux-audit-captures/') && !file.startsWith('docs/ui-ux-audit-inputs/'))
        .filter(file => fs.existsSync(path.join(root, file)) && fs.statSync(path.join(root, file)).isFile() && !fs.lstatSync(path.join(root, file)).isSymbolicLink())
        .sort();
    } catch { /* A source archive without Git can still be inspected. */ }
  }

  return fs.readdirSync(path.join(root, directory), { withFileTypes: true }).flatMap(entry => {
    const relative = path.posix.join(directory, entry.name);

    if (excluded.has(entry.name) || entry.isSymbolicLink()) return [];

    if (entry.isDirectory()) return sourceFiles(root, relative);

    if (relative.startsWith('tests/e2e/artifacts/') || relative.startsWith('docs/ui-ux-audit-captures/') || relative.startsWith('docs/ui-ux-audit-inputs/')) return [];

    if (entry.name.startsWith('.env') && !entry.name.endsWith('.example')) return [];

    return [relative];
  }).sort();
}

export function fingerprint(root) {
  const digest = crypto.createHash('sha256');

  for (const file of sourceFiles(root)) {
    if (file === '.quality/documents.json' || file === '.quality/test-inventory.json' || file === 'src/verification/test-inventory.json' || /\.(png|jpg|jpeg|gif|riv|jar|ico|tsbuildinfo)$/.test(file)) continue;

    if (/\.(pem|key|apk|aab|dump|bak)$/.test(file)) continue;
    const absolute = path.join(root, file);

    if (fs.statSync(absolute).size > 4 * 1024 * 1024) continue;
    digest.update(file).update('\0').update(fs.readFileSync(absolute)).update('\0');
  }

  return digest.digest('hex');
}

export function discoverTests(root, config) {
  let ts;

  try { ts = createRequire(path.join(root, 'package.json'))('typescript'); } catch { /* Flutter has a native runner. */ }

  const tests = [];
  const metadata = config.coverage ?? {};

  for (const file of sourceFiles(root)) {
    const isE2e = file.startsWith('tests/e2e/suites/') && file.endsWith('.ts') && !file.endsWith('/index.ts');
    const isDart = file.endsWith('_test.dart');
    const isDeclaredScript=metadata[file]?.standalone===true;

    if (!isDeclaredScript && !isE2e && !isDart && !/\.(test|spec)\.[cm]?[jt]sx?$/.test(file)) continue;
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const entries = [];

    if(isDeclaredScript){
      entries.push({title:path.basename(file),line:1,discovery:'declared-script'});
    } else if (isDart) {
      // Dart files are indexed at native file granularity; runtime test events can refine case names.
      entries.push({ title: path.basename(file), line: 1, discovery: 'native-file' });
    } else if (ts) {
      const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
      const literal = node => node && (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) ? node.text : null;

      const visit = (node, parents = []) => {
        if (isE2e && ts.isObjectLiteralExpression(node)) {
          const properties = new Map(node.properties.filter(ts.isPropertyAssignment).map(p => [p.name.getText(tree).replace(/^['"]|['"]$/g, ''), p.initializer]));
          const title = literal(properties.get('name'));

          if (title && properties.has('run')) entries.push({ title, line: tree.getLineAndCharacterOfPosition(node.getStart(tree)).line + 1, discovery: 'typescript-ast' });
        }

        if (!isE2e && ts.isCallExpression(node)) {
          const expression = node.expression.getText(tree);
          const title = literal(node.arguments[0]);

          if (title && /^(describe|suite)(\.|$)/.test(expression)) {
            for (const child of node.arguments.slice(1)) visit(child, [...parents, title]);

            return;
          }

          if (title && /^(it|test)(\.|$)/.test(expression)) entries.push({ title: [...parents, title].join(' › '), line: tree.getLineAndCharacterOfPosition(node.getStart(tree)).line + 1, discovery: 'typescript-ast' });
        }

        ts.forEachChild(node, child => visit(child, parents));
      };

      visit(tree);

      if (!entries.length) entries.push({ title: path.basename(file), line: 1, discovery: 'file-unresolved' });
    } else entries.push({ title: path.basename(file), line: 1, discovery: 'file-unresolved' });

    for (const entry of entries) {
      const annotation = metadata[`${file}#${entry.title}`] ?? metadata[file];
      const runner = annotation?.runner ?? (isE2e ? 'api-e2e' : isDart ? 'flutter' : config.runner);
      tests.push({ id: `${config.repository}:${hash(file + '\0' + entry.title).slice(0, 20)}`, repository: config.repository, source: file, ...entry,
        runner, level: annotation?.level ?? (isE2e ? 'business' : isDart ? 'hardware-adapter' : 'technical'),
        behavior: annotation?.behavior ?? null, ruleIds: annotation?.ruleIds ?? [], scenarioIds: annotation?.scenarioIds ?? [],
        command: annotation?.command ?? (isE2e ? `E2E_SUITE='${entry.title.replace(/'/g, '')}' npm run test:e2e` : isDart ? `flutter test ${file}` : `npm test -- ${file}`),
        metadataStatus: annotation ? 'documented' : 'needs-classification',
        limitations: [...(annotation?.limitations ?? []), ...(entry.discovery === 'native-file' ? ['Native file inventory; individual outcomes require Flutter reporter evidence.'] : []), ...(entry.discovery === 'file-unresolved' ? ['Dynamic case names require runner discovery; no executable case is inferred.'] : [])],
      });
    }
  }

  return { version: 2, repository: config.repository, tests };
}

export function documentInventory(root, config) {
  return { version: 1, documents: sourceFiles(root).filter(file => /\.md$/i.test(file)).map(file => {
    const policy = config.documents?.[file] ?? config.documentGroups?.find(group => file.startsWith(group.prefix));

    return { path: file, classification: policy?.classification ?? 'unregistered', owner: policy?.owner ?? null, purpose: policy?.purpose ?? null, originalPath: policy?.originalPath ?? null };
  }) };
}

function expectedAgent(config, policy) {
  return `# ${config.repository} development\n\n<!-- BEGIN GENERATED CONTRACT ${policy.digest} -->\n${policy.text.trim()}\n<!-- END GENERATED CONTRACT -->\n\n## Repository guidance\n\n${config.localGuidance.trim()}\n`;
}

export function syncRepository(root) {
  const config = readJson(path.join(root, '.quality/config.json'));
  const policy = readJson(path.join(root, '.quality/policy.json'));
  fs.writeFileSync(path.join(root, 'AGENTS.md'), expectedAgent(config, policy));
  fs.writeFileSync(path.join(root, 'CLAUDE.md'), '# Coding instructions\n\nRead [AGENTS.md](AGENTS.md) before making changes. It contains the shared development contract and repository-specific guidance.\n');
  fs.writeFileSync(path.join(root, '.quality/test-inventory.json'), JSON.stringify(discoverTests(root, config), null, 2) + '\n');
  fs.writeFileSync(path.join(root, '.quality/documents.json'), JSON.stringify(documentInventory(root, config), null, 2) + '\n');
}

function changedFiles(root, base) {
  if (!base) throw new Error('--base=<commit> is required for changed mode');
  git(root, ['rev-parse', '--verify', `${base}^{commit}`]);

  return [...new Set([...git(root, ['diff', '--name-only', base, '--']).trim().split('\n'), ...git(root, ['ls-files', '--others', '--exclude-standard']).trim().split('\n')].filter(Boolean))];
}

function checkSecret(file, source) {
  if (/(^|\/)(test|tests|fixtures)\//.test(file) || /\.test\.|\.example$/.test(file)) return [];

  return [/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/, /\bgh[pousr]_[A-Za-z0-9]{30,}\b/, /\bgithub_pat_[A-Za-z0-9_]{40,}\b/].flatMap(pattern => pattern.test(source)?[`Possible secret in ${file}; values are suppressed`]:[]);
}

function referenceErrors(root, authority, policy) {
  const errors = [], seen = new Set();

  if (policy.version >= 2 && (!Array.isArray(policy.resources) || !policy.resources.length)) return ['Missing generated reference manifest'];

  const validPath = value => {
    try {
      match(value, /^[\w./-]+$/);

      return !path.isAbsolute(value) && !value.split('/').some(part => !part || part === '.' || part === '..');
    } catch { return false; }
  };

  const matches = (base, relative, expected) => {
    const absolute = path.join(base, relative);

    if (!fs.existsSync(absolute) || fs.lstatSync(absolute).isSymbolicLink() || !fs.statSync(absolute).isFile()) return false;

    if (!fs.realpathSync(absolute).startsWith(fs.realpathSync(base) + path.sep)) return false;

    return hash(fs.readFileSync(absolute)) === expected;
  };

  for (const resource of policy.resources ?? []) {
    if (!resource || !validPath(resource.source) || !validPath(resource.target) || !/^[a-f0-9]{64}$/.test(resource.sha256) || seen.has(resource.target)) {
      errors.push('Invalid generated reference manifest'); continue;
    }

    seen.add(resource.target);

    if (!matches(root, resource.target, resource.sha256)) errors.push('Generated reference missing or changed: ' + resource.target + '; run quality:sync');

    if (fs.existsSync(path.join(authority, 'docs/development/agent-contract.md')) && !matches(authority, resource.source, resource.sha256)) errors.push('Canonical reference changed: ' + resource.source + '; run quality:sync');
  }

  return errors;
}

export function structuralCheck(root, config, policy, { changed = null } = {}) {
  const errors = [], warnings = [];
  const inventory = discoverTests(root, config);
  const documents = documentInventory(root, config);

  if (hash(policy.text) !== policy.digest) errors.push('Policy digest mismatch');

  if (fs.readFileSync(path.join(root, 'AGENTS.md'), 'utf8') !== expectedAgent(config, policy)) errors.push('Generated AGENTS.md diverges; run quality:sync');
  const authority = path.resolve(root, config.authority ?? '../chimera');
  const canonicalPolicy = path.join(authority, 'docs/development/agent-contract.md');
  errors.push(...referenceErrors(root, authority, policy));

  if (fs.existsSync(canonicalPolicy) && fs.readFileSync(canonicalPolicy, 'utf8') !== policy.text) errors.push('Shared contract differs from canonical source');
  const canonicalRuntime = path.join(authority, 'tools/quality/runtime.mjs');

  if (fs.existsSync(canonicalRuntime) && fs.readFileSync(canonicalRuntime, 'utf8') !== fs.readFileSync(path.join(root, '.quality/runtime.mjs'), 'utf8')) errors.push('Quality runtime differs from canonical source');

  for (const [file, value] of [['.quality/test-inventory.json', inventory], ['.quality/documents.json', documents]]) {
    if (!fs.existsSync(path.join(root, file)) || fs.readFileSync(path.join(root, file), 'utf8') !== JSON.stringify(value, null, 2) + '\n') errors.push(`${file} is stale; run quality:sync`);
  }

  const seen = new Set();
  const referenceFile = path.join(root, '.quality/references.json');
  const references = fs.existsSync(referenceFile) ? readJson(referenceFile) : null;

  if (references) {
    for (const kind of ['ruleIds', 'scenarioIds']) {
      if (new Set(references[kind]).size !== references[kind].length) errors.push(`Duplicate IDs in ${kind} reference index`);
    }
  }

  for (const test of inventory.tests) {
    if (seen.has(test.id)) errors.push(`Duplicate test ID: ${test.source} ${test.title}`);
    seen.add(test.id);

    for (const kind of ['ruleIds', 'scenarioIds']) {
      for (const id of test[kind]) if (!references?.[kind]?.includes(id)) errors.push(`Unknown ${kind} reference ${id}: ${test.source}`);
    }

    if (!test.behavior) warnings.push(`Historical metadata gap: ${test.source} ${test.title}`);

    if (changed?.includes(test.source) && !test.behavior && !config.existingTests?.includes(test.source)) errors.push(`New test needs coverage metadata: ${test.source}`);
  }

  let scripts = {};

  if (fs.existsSync(path.join(root, 'package.json'))) scripts = readJson(path.join(root, 'package.json')).scripts ?? {};

  for (const document of documents.documents) {
    if (document.classification === 'unregistered') errors.push(`Document must be registered: ${document.path}`);

    if (document.classification === 'historical' || document.classification === 'active-work') continue;
    const contents = fs.readFileSync(path.join(root, document.path), 'utf8');

    for (const match of contents.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
      const target = match[1].split(/\s+['"]/)[0].replace(/^<|>$/g, '').split('#')[0];

      if (!target || /^(https?:|mailto:|codex:|app:)/.test(target)) continue;
      let local;

      try { local = decodeURIComponent(target); } catch { errors.push(`Invalid link encoding in ${document.path}`); continue; }

      const absolute = path.resolve(path.dirname(path.join(root, document.path)), local.replace(/:\d+$/, ''));

      if (!fs.existsSync(absolute)) {
        if (!absolute.startsWith(root + path.sep)) warnings.push(`Cross-repository link unavailable in this checkout: ${document.path}`);
        else errors.push(`Broken link: ${document.path} → ${target}`);
      }
    }

    for (const match of contents.matchAll(/npm run ([\w:-]+)/g)) {
      const command = match[1].replace(/[.,;:]$/, '');

      if (!scripts[command] && !command.includes('<') && !config.foreignCommands?.includes(command)) errors.push(`Unknown npm script in ${document.path}: ${command}`);
    }
  }

  for (const file of changed ?? sourceFiles(root)) {
    if (!fs.existsSync(path.join(root, file)) || fs.statSync(path.join(root, file)).size > 1024 * 1024) continue;

    if (/\.(apk|aab|dump|bak|key|keystore|p12|pfx)$/.test(file)) errors.push(`Local/private artifact must not be committed: ${file}`);

    if (/\.(ts|tsx|js|mjs|cjs|json|md|ya?ml|sql|dart)$/.test(file)) errors.push(...checkSecret(file, fs.readFileSync(path.join(root, file), 'utf8')));
  }

  const impacts = changed ? changed.map(file => ({ file, groups: (config.impact ?? []).filter(group => group.prefixes.some(prefix => file.startsWith(prefix))) })) : [];

  if(config.repository==='chimera'&&fs.existsSync(path.join(root,'.quality/sql-boundary.json'))){
    const boundary=spawnSync(process.execPath,['tools/quality/sql-boundary.mjs'],{cwd:root,encoding:'utf8',timeout:30000});

    if(boundary.status!==0)errors.push(`SQL boundary check failed: ${boundary.stdout||boundary.stderr}`);
  }

  for (const impact of impacts) {
    if (!impact.groups.length && /\.(ts|tsx|js|mjs|cjs|sql|dart|kt)$/.test(impact.file) && !impact.file.startsWith('.quality/')) errors.push(`Unmapped functional change: ${impact.file}`);
  }

  const justificationFile = path.join(root, '.quality/change.json');
  const justification = fs.existsSync(justificationFile) ? readJson(justificationFile) : null;
  const functional = impacts.filter(item => /\.(ts|tsx|sql|dart|kt)$/.test(item.file) && !/\.test\.|_test\./.test(item.file));

  if (functional.length && (!justification?.behavior || !justification?.verification || !justification?.canonicalDocuments?.length)) errors.push('Functional changes require .quality/change.json with behavior, verification and canonicalDocuments');

  if (functional.length && justification?.canonicalDocuments) {
    for (const file of justification.canonicalDocuments) if (!fs.existsSync(path.join(root, file))) errors.push(`Change references missing documentation: ${file}`);
    const references = justification.verification?.tests ?? [];

    for (const file of references) if (!inventory.tests.some(test => test.source === file)) errors.push(`Change references unknown test source: ${file}`);

    if (!references.length && !justification.verification?.justification) errors.push('Functional change needs test sources or an explicit verification justification');
  }

  return { errors, warnings, inventory, impacts };
}

export function parseQualityOptions(args) {
  const option = name => {
    const inline = args.find(arg => arg.startsWith(`--${name}=`));

    if (inline) return inline.slice(name.length + 3);
    const index = args.indexOf(`--${name}`);

    return index >= 0 && args[index + 1] && !args[index + 1].startsWith('--') ? args[index + 1] : undefined;
  };

  const mode = option('mode') ?? (args.includes('--changed') ? 'changed' : args.includes('--release') ? 'release' : 'quick');

  if (!['quick', 'changed', 'release'].includes(mode)) throw new Error('Mode must be quick, changed or release');
  const base = option('base') ?? null;

  if (mode === 'changed' && !base) throw new Error('Changed mode requires an explicit --base commit');

  return { mode, base };
}

export function main(root = process.cwd(), args = process.argv.slice(2)) {
  if (args.includes('--fingerprint')) { console.log(fingerprint(root));

 return; }

  if (args.includes('--install-hook')) {
    let current = '';

    try { current = git(root, ['config', '--get', 'core.hooksPath']).trim(); } catch { /* No configured hook directory. */ }

    if (current && current !== '.githooks') throw new Error('Existing hooksPath preserved; integrate quality checks manually');
    const directory = path.join(root, '.githooks');
    fs.mkdirSync(directory, { recursive: true });
    const hook = path.join(directory, 'pre-commit');
    const content = '#!/bin/sh\nset -eu\nnode .quality/runtime.mjs --mode=quick\n';

    if (fs.existsSync(hook) && fs.readFileSync(hook, 'utf8') !== content) throw new Error('Existing pre-commit hook preserved; integrate quality checks manually');
    fs.writeFileSync(hook, content); fs.chmodSync(hook, 0o755);
    git(root, ['config', 'core.hooksPath', '.githooks']);
    console.log('Installed quick quality hook; costly checks remain explicit');

 return;
  }

  const config = readJson(path.join(root, '.quality/config.json'));
  const policy = readJson(path.join(root, '.quality/policy.json'));

  if (args.includes('--sync')) { syncRepository(root); console.log(`Synchronized ${config.repository}`);

 return; }

  const { mode, base } = parseQualityOptions(args);
  const changed = mode === 'changed' ? changedFiles(root, base) : null;
  const started = new Date().toISOString();
  const sourceFingerprint = fingerprint(root);
  const result = structuralCheck(root, config, policy, { changed });
  const commands = [];
  const skipped = [];
  const selected = mode === 'release' ? config.releaseChecks ?? [] : mode === 'changed' ? [...new Map(result.impacts.flatMap(item => item.groups.flatMap(group => group.checks ?? [])).map(command => [JSON.stringify(command), command])).values()] : [];

  if (!result.errors.length && !args.includes('--defer-tests')) {
    for (const command of selected) {
      const start = Date.now();
      const child = spawnSync(command[0], command.slice(1), { cwd: root, encoding: 'utf8', timeout: config.checkTimeoutMs ?? 180000 });
      commands.push({ command, exitCode: child.status, durationMs: Date.now() - start });
      process.stdout.write(child.stdout ?? ''); process.stderr.write(child.stderr ?? '');

      if (child.status !== 0) { result.errors.push(`Check failed: ${command.join(' ')}`); break; }
    }
  } else if (selected.length) {
    const reason = option('reason');

    if (args.includes('--defer-tests') && !reason) result.errors.push('--defer-tests requires --reason=<reason>');
    skipped.push(...selected.map(command => ({ command, reason: reason ?? 'Structural checks failed' })));
  }

  const finalFingerprint = fingerprint(root);

  if (finalFingerprint !== sourceFingerprint) result.errors.push('Sources changed during verification; rerun selected checks');

  const receipt = { version: 1, repository: config.repository, mode, base, startedAt: started, completedAt: new Date().toISOString(), sourceFingerprint, current: finalFingerprint === sourceFingerprint,
    result: result.errors.length ? 'failed' : skipped.length ? 'deferred' : 'passed', commands, skipped, errors: result.errors, warnings: result.warnings,
    testCount: result.inventory.tests.length, unclassifiedTests: result.inventory.tests.filter(item => !item.behavior).length };

  const receiptDir = path.join(root, '.quality-receipts');
  fs.mkdirSync(receiptDir, { recursive: true });
  fs.writeFileSync(path.join(receiptDir, 'latest.json'), JSON.stringify(receipt, null, 2) + '\n');
  console.log(JSON.stringify({ repository: config.repository, result: receipt.result, errors: receipt.errors, historicalMetadataGaps: receipt.unclassifiedTests, warnings: receipt.warnings.length, receipt: '.quality-receipts/latest.json' }, null, 2));

  if (result.errors.length) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
