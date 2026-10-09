import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';

const read = (path) => JSON.parse(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8'));
export const reportSchema = read('schemas/capabilities.v1.schema.json');
export const errorSchema = read('schemas/capability-error.v1.schema.json');
export const report = read('fixtures/capabilities.v1.json');
export const error = read('fixtures/capability-error.v1.json');
const ajv = new Ajv2020({ allErrors: true });
ajv.addSchema(reportSchema);
export const validateReport = ajv.getSchema(reportSchema.$id);
export const validateError = ajv.compile(errorSchema);
for (const [validate, fixture] of [[validateReport, report], [validateError, error]]) {
  if (!validate(fixture)) throw new Error(JSON.stringify(validate.errors));
}
