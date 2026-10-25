import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';

const read = (path) => JSON.parse(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8'));
export const reportSchema = read('schemas/capabilities.v1.schema.json');
export const errorSchema = read('schemas/capability-error.v1.schema.json');
export const agentsSchema = read('schemas/agents.v1.schema.json');
export const statusSchema = read('schemas/status.v1.schema.json');
export const ticketSchema = read('schemas/ticket.v1.schema.json');
export const ticketCancelSchema = read('schemas/ticket-cancel.v1.schema.json');
export const ticketUsageSchema = read('schemas/ticket-usage.v1.schema.json');
export const ticketProgressSchema = read('schemas/ticket-progress.v1.schema.json');
export const report = read('fixtures/capabilities.v1.json');
export const error = read('fixtures/capability-error.v1.json');
export const agents = read('fixtures/agents.v1.json');
export const status = read('fixtures/status.v1.json');
export const ticket = read('fixtures/ticket.v1.json');
export const ticketCancel = read('fixtures/ticket-cancel.v1.json');
export const ticketUsage = read('fixtures/ticket-usage.v1.json');
export const ticketProgress = read('fixtures/ticket-progress.v1.json');
const ajv = new Ajv2020({ allErrors: true });
for (const schema of [
  reportSchema,
  agentsSchema,
  statusSchema,
  ticketSchema,
  ticketCancelSchema,
  ticketUsageSchema,
  ticketProgressSchema,
]) {
  ajv.addSchema(schema);
}
export const validateReport = ajv.getSchema(reportSchema.$id);
export const validateError = ajv.compile(errorSchema);
export const validateAgents = ajv.getSchema(agentsSchema.$id);
export const validateStatus = ajv.getSchema(statusSchema.$id);
export const validateTicket = ajv.getSchema(ticketSchema.$id);
export const validateTicketCancel = ajv.getSchema(ticketCancelSchema.$id);
export const validateTicketUsage = ajv.getSchema(ticketUsageSchema.$id);
export const validateTicketProgress = ajv.getSchema(ticketProgressSchema.$id);

export const contractCases = [
  { name: 'agents', schema: agentsSchema, fixture: agents, validate: validateAgents },
  { name: 'status', schema: statusSchema, fixture: status, validate: validateStatus },
  { name: 'ticket', schema: ticketSchema, fixture: ticket, validate: validateTicket },
  { name: 'ticket cancel', schema: ticketCancelSchema, fixture: ticketCancel, validate: validateTicketCancel },
  { name: 'ticket usage', schema: ticketUsageSchema, fixture: ticketUsage, validate: validateTicketUsage },
  { name: 'ticket progress', schema: ticketProgressSchema, fixture: ticketProgress, validate: validateTicketProgress },
];

for (const [validate, fixture] of [
  [validateReport, report],
  [validateError, error],
  ...contractCases.map(({ validate, fixture }) => [validate, fixture]),
]) {
  if (!validate(fixture)) throw new Error(JSON.stringify(validate.errors));
}
