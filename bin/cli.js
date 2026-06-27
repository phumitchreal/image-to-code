#!/usr/bin/env node
/**
 * image-to-code — npm wrapper.
 * Bundles Python source. Installs pip deps on first run, then delegates.
 * On first run, also installs as opencode skill.
 */
const { execSync, spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");

const MODULE_DIR = path.resolve(__dirname, "..");
const PYTHON_MODULE = "image_to_code";

const OPECODE_SKILL_DIR = path.join(os.homedir(), ".opencode", "skills", PYTHON_MODULE);

function checkPython() {
  for (const cmd of ["python", "python3"]) {
    try {
      execSync(`${cmd} --version`, { stdio: "pipe", timeout: 10000 });
      return cmd;
    } catch {
      // try next
    }
  }
  return null;
}

function ensurePipDeps(python) {
  try {
    execSync(`${python} -c "import PIL; import pytesseract" 2>${process.platform === "win32" ? "nul" : "/dev/null"}`, {
      stdio: "pipe",
      timeout: 10000,
    });
    return;
  } catch {
    // install deps
  }
  console.log("→ Installing Python dependencies (Pillow, pytesseract)...");
  execSync(
    `${python} -m pip install Pillow>=10.0.0 pytesseract>=0.3.10 --quiet`,
    { stdio: "inherit", timeout: 120000 }
  );
}

function installOpencodeSkill() {
  const skillMdPath = path.join(MODULE_DIR, "SKILL.md");
  const opencodeJsonPath = path.join(MODULE_DIR, "opencode.json");
  if (!fs.existsSync(skillMdPath)) return;

  // Only install if SKILL.md doesn't exist in opencode skills dir
  const targetMd = path.join(OPECODE_SKILL_DIR, "SKILL.md");
  if (fs.existsSync(targetMd)) return;

  try {
    fs.mkdirSync(OPECODE_SKILL_DIR, { recursive: true });
    fs.copyFileSync(skillMdPath, targetMd);
    if (fs.existsSync(opencodeJsonPath)) {
      fs.copyFileSync(opencodeJsonPath, path.join(OPECODE_SKILL_DIR, "opencode.json"));
    }
    console.log(`  → Registered opencode skill: ~/.opencode/skills/${PYTHON_MODULE}/`);
  } catch (e) {
    console.error(`  ⚠ Could not install opencode skill: ${e.message}`);
  }
}

function main() {
  // Install opencode skill on first run
  installOpencodeSkill();

  const python = checkPython();
  if (!python) {
    console.error("✖ Python not found. Install Python 3.10+ from https://python.org");
    process.exit(1);
  }

  ensurePipDeps(python);

  const args = process.argv.slice(2);
  const child = spawn(python, ["-m", PYTHON_MODULE + ".analyze", ...args], {
    stdio: "inherit",
    env: {
      ...process.env,
      PYTHONPATH: MODULE_DIR + (process.env.PYTHONPATH ? path.delimiter + process.env.PYTHONPATH : ""),
      PYTHONIOENCODING: "utf-8",
    },
  });
  child.on("exit", (code) => process.exit(code));
}

main();
