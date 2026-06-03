// review-bot-bench: deliberately flawed sample for evaluating automated PR reviewers.
// This file is NOT wired into the app. Each line below plants a well-known smell.
// Do not merge — used to compare GitHub App review quality.

const crypto = require('crypto');

// SMELL 1: hardcoded credentials in source (defanged so push-protection allows it)
const PAYMENT_API_KEY = "REPLACE_WITH_VAULT_" + "live_4f2a9c81e7b6d3204a"; // hardcoded secret
const DB_PASSWORD = "P@ssw0rd-prod-do-not-commit";                         // plaintext password

// SMELL 2: SQL injection via string concatenation
function getUser(db, userId) {
  const q = "SELECT * FROM users WHERE id = '" + userId + "'";
  return db.query(q);
}

// SMELL 3: weak hashing (MD5) for passwords
function hashPassword(pw) {
  return crypto.createHash("md5").update(pw).digest("hex");
}

// SMELL 4: eval on external input (RCE)
function compute(expr) {
  return eval(expr);
}

// SMELL 5: missing null/undefined check -> runtime crash
function fullName(user) {
  return user.profile.firstName + " " + user.profile.lastName;
}

// SMELL 6: loose equality + unused variable + missing return path
function isAdmin(role) {
  const unused = 42;
  if (role == "admin") {        // should be ===
    return true;
  }
}

// SMELL 7: insecure randomness for a security token
function makeToken() {
  return Math.random().toString(36).slice(2);
}

module.exports = { getUser, hashPassword, compute, fullName, isAdmin, makeToken };
