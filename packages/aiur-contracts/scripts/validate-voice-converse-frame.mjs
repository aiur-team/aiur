import { validateVoiceConverse } from './validate.mjs';

let frame;

try {
  frame = JSON.parse(process.argv[2] ?? await new Promise((resolve, reject) => {
    let input = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => (input += chunk));
    process.stdin.on('end', () => resolve(input));
    process.stdin.on('error', reject);
  }));
} catch (error) {
  console.error(`invalid JSON: ${error.message}`);
  process.exit(1);
}

if (!validateVoiceConverse([frame])) {
  console.error(JSON.stringify(validateVoiceConverse.errors));
  process.exit(1);
}
