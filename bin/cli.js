#!/usr/bin/env node
/**
 * image-to-code — npm wrapper.
 * Auto-installs the Python package via pip on first run, then delegates.
 */
const { execSync, spawn } = require("child_process");
const path = require("path");

const PYTHON_MODULE = "image_to_code";
const REQUIRED_DEPS = ["Pillow>=10.0.0", "pytesseract>=0.3.10"];

function checkPython() {
  try {
    execSync("python --version", { stdio: "pipe", timeout: 10000 });
    return "python";
  } catch {
    try {
      execSync("python3 --version", { stdio: "pipe", timeout: 10000 });
      return "python3";
    } catch {
      return null;
    }
  }
}

function checkPackage(python) {
  try {
    execSync(`${python} -c "import ${PYTHON_MODULE}"`, {
      stdio: "pipe",
      timeout: 10000,
    });
    return true;
  } catch {
    return false;
  }
}

function installPackage(python) {
  console.log("→ Installing image-to-code Python package...");
  execSync(`${python} -m pip install ${PYTHON_MODULE} --upgrade`, {
    stdio: "inherit",
    timeout: 120000,
  });
}

function main() {
  const python = checkPython();
  if (!python) {
    console.error(
      "✖ Python not found. Install Python 3.10+ from https://python.org"
    );
    process.exit(1);
  }

  if (!checkPackage(python)) {
    installPackage(python);
  }

  const args = process.argv.slice(2);
  const child = spawn(python, ["-m", PYTHON_MODULE + ".analyze", ...args], {
    stdio: "inherit",
  });
  child.on("exit", (code) => process.exit(code));
}

main();
