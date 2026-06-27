#!/usr/bin/env node
/**
 * image-to-code — npm wrapper.
 * Bundles Python source. Installs pip deps on first run, then delegates.
 */
const { execSync, spawn } = require("child_process");
const path = require("path");

const MODULE_DIR = path.resolve(__dirname, "..");
const PYTHON_MODULE = "image_to_code";

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
    return; // deps already installed
  } catch {
    // install deps
  }
  console.log("→ Installing Python dependencies (Pillow, pytesseract)...");
  execSync(
    `${python} -m pip install Pillow>=10.0.0 pytesseract>=0.3.10 --quiet`,
    { stdio: "inherit", timeout: 120000 }
  );
}

function main() {
  const python = checkPython();
  if (!python) {
    console.error(
      "✖ Python not found. Install Python 3.10+ from https://python.org"
    );
    process.exit(1);
  }

  ensurePipDeps(python);

  const args = process.argv.slice(2);
  const child = spawn(python, ["-m", PYTHON_MODULE + ".analyze", ...args], {
    stdio: "inherit",
    env: {
      ...process.env,
      PYTHONPATH: MODULE_DIR + (process.env.PYTHONPATH ? path.delimiter + process.env.PYTHONPATH : ""),
    },
  });
  child.on("exit", (code) => process.exit(code));
}

main();
