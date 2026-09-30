#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const versionFile = resolve(repositoryRoot, "Version.xcconfig");
const levels = new Set(["major", "minor", "patch"]);

function fail(message) {
  throw new Error(message);
}

function git(args, options = {}) {
  try {
    const output = execFileSync("git", args, {
      cwd: repositoryRoot,
      encoding: "utf8",
      stdio: options.inherit ? "inherit" : ["ignore", "pipe", "pipe"],
    });
    return typeof output === "string" ? output.trim() : "";
  } catch (error) {
    const detail = error.stderr?.trim();
    fail(detail ? `${options.description ?? "git command failed"}: ${detail}` :
      options.description ?? "git command failed");
  }
}

function gitSucceeds(args) {
  return spawnSync("git", args, {
    cwd: repositoryRoot,
    stdio: "ignore",
  }).status === 0;
}

function parseArguments(arguments_) {
  let level;
  let assumeYes = false;
  let dryRun = false;

  for (const argument of arguments_) {
    if (levels.has(argument)) {
      if (level) fail("只能指定一个版本级别");
      level = argument;
    } else if (argument === "--yes" || argument === "-y") {
      assumeYes = true;
    } else if (argument === "--dry-run") {
      dryRun = true;
    } else if (argument === "--help" || argument === "-h") {
      console.log(`用法：
  pnpm bump                 交互式选择版本级别
  pnpm bump patch          直接选择 patch，执行前仍会确认
  pnpm bump minor --yes    跳过确认
  pnpm bump major --dry-run

脚本会更新 Version.xcconfig、创建 release commit 和 vMAJOR.MINOR.PATCH tag，
但不会 push。`);
      process.exit(0);
    } else {
      fail(`未知参数：${argument}`);
    }
  }

  return { level, assumeYes, dryRun };
}

function readVersion() {
  const source = readFileSync(versionFile, "utf8");
  const matches = [...source.matchAll(/^(\s*MARKETING_VERSION\s*=\s*)(\d+)\.(\d+)\.(\d+)(\s*)$/gm)];
  if (matches.length !== 1) {
    fail("Version.xcconfig 必须包含且只能包含一个 MAJOR.MINOR.PATCH 格式的 MARKETING_VERSION");
  }

  const match = matches[0];
  const numbers = match.slice(2, 5).map(Number);
  if (numbers.some((value) => !Number.isSafeInteger(value))) {
    fail("当前版本号超出安全整数范围");
  }
  return { source, match, numbers, version: numbers.join(".") };
}

function nextVersion(numbers, level) {
  let [major, minor, patch] = numbers;
  if (level === "major") {
    major += 1;
    minor = 0;
    patch = 0;
  } else if (level === "minor") {
    minor += 1;
    patch = 0;
  } else {
    patch += 1;
  }
  if (![major, minor, patch].every(Number.isSafeInteger)) {
    fail("目标版本号超出安全整数范围");
  }
  return `${major}.${minor}.${patch}`;
}

function replaceVersion({ source, match }, version) {
  const replacement = `${match[1]}${version}${match[5]}`;
  return source.slice(0, match.index) + replacement +
    source.slice(match.index + match[0].length);
}

async function chooseLevel(prompt, current) {
  const choices = [
    ["1", "patch", nextVersion(current.numbers, "patch")],
    ["2", "minor", nextVersion(current.numbers, "minor")],
    ["3", "major", nextVersion(current.numbers, "major")],
  ];
  console.log(`当前版本：v${current.version}\n`);
  for (const [number, name, version] of choices) {
    console.log(`  ${number}) ${name.padEnd(5)} -> v${version}`);
  }

  while (true) {
    const answer = (await prompt.question("\n请选择更新级别 [1-3]：")).trim().toLowerCase();
    const choice = choices.find(([number, name]) => answer === number || answer === name);
    if (choice) return choice[1];
    console.log("请输入 1、2、3，或 patch、minor、major。");
  }
}

function validateRepository() {
  const root = git(["rev-parse", "--show-toplevel"], {
    description: "当前目录不是 Git 仓库",
  });
  if (resolve(root) !== repositoryRoot) {
    fail(`脚本所在仓库与 Git 根目录不一致：${root}`);
  }

  const status = git(["status", "--porcelain=v1", "--untracked-files=normal"]);
  if (status) {
    fail("工作区存在未提交改动；请先提交或暂存处理后再执行 pnpm bump");
  }

  const branch = git(["branch", "--show-current"]);
  if (!branch) fail("当前处于 detached HEAD，无法创建发布 commit");

  git(["var", "GIT_AUTHOR_IDENT"], { description: "Git 用户信息不可用" });
  return branch;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const branch = validateRepository();
  const current = readVersion();
  let prompt;

  try {
    if (!options.level) {
      if (!stdin.isTTY || !stdout.isTTY) {
        fail("非交互环境中请显式指定 major、minor 或 patch");
      }
      prompt = createInterface({ input: stdin, output: stdout });
      options.level = await chooseLevel(prompt, current);
    }

    const version = nextVersion(current.numbers, options.level);
    const tag = `v${version}`;
    if (gitSucceeds(["show-ref", "--verify", "--quiet", `refs/tags/${tag}`])) {
      fail(`本地 tag ${tag} 已存在`);
    }

    console.log(`\n准备执行：
  分支：${branch}
  版本：v${current.version} -> ${tag}
  commit：chore(release): bump version to ${version}
  tag：${tag}
  push：不会执行`);

    if (options.dryRun) {
      console.log("\nDry run 完成，未修改任何文件。");
      return;
    }

    if (!options.assumeYes) {
      prompt ??= createInterface({ input: stdin, output: stdout });
      const answer = (await prompt.question("\n确认继续？[y/N]：")).trim().toLowerCase();
      if (answer !== "y" && answer !== "yes") {
        console.log("已取消，未修改任何文件。");
        return;
      }
    }

    const updatedSource = replaceVersion(current, version);
    writeFileSync(versionFile, updatedSource);

    try {
      git(["add", "--", "Version.xcconfig"], { description: "暂存版本文件失败" });
      git(["commit", "-m", `chore(release): bump version to ${version}`], {
        description: "创建 release commit 失败",
        inherit: true,
      });
    } catch (error) {
      writeFileSync(versionFile, current.source);
      spawnSync("git", ["restore", "--staged", "--", "Version.xcconfig"], {
        cwd: repositoryRoot,
        stdio: "ignore",
      });
      throw error;
    }

    git(["tag", "-a", tag, "-m", `CoreS3 Companion ${tag}`], {
      description: `创建 tag ${tag} 失败`,
    });
    const commit = git(["rev-parse", "--short", "HEAD"]);

    console.log(`\n完成：
  commit：${commit}
  tag：${tag}

脚本没有 push。检查无误后手动触发发布：
  git push origin ${branch} ${tag}`);
  } finally {
    prompt?.close();
  }
}

main().catch((error) => {
  console.error(`\n错误：${error.message}`);
  process.exitCode = 1;
});
