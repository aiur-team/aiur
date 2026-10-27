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
export const ticketSpendCapSchema = read('schemas/ticket-spend-cap.v1.schema.json');
export const ticketSpendCapReachedSchema = read('schemas/ticket-spend-cap-reached.v1.schema.json');
export const voiceConverseSchema = read('schemas/voice-converse.v1.schema.json');
export const report = read('fixtures/capabilities.v1.json');
export const error = read('fixtures/capability-error.v1.json');
export const agents = read('fixtures/agents.v1.json');
export const status = read('fixtures/status.v1.json');
export const ticket = read('fixtures/ticket.v1.json');
export const ticketCancel = read('fixtures/ticket-cancel.v1.json');
export const ticketUsage = read('fixtures/ticket-usage.v1.json');
export const ticketProgress = read('fixtures/ticket-progress.v1.json');
export const ticketSpendCap = read('fixtures/ticket-spend-cap.v1.json');
export const ticketSpendCapReached = read('fixtures/ticket-spend-cap-reached.v1.json');
export const voiceConverse = read('fixtures/voice-converse.v1.json');
export const commandSchema = read('schemas/command.v2.schema.json');
export const command = read('fixtures/command.v2.json');
const ajv = new Ajv2020({ allErrors: true });
for (const schema of [
  reportSchema,
  agentsSchema,
  statusSchema,
  ticketSchema,
  ticketCancelSchema,
  ticketUsageSchema,
  ticketProgressSchema,
  ticketSpendCapSchema,
  ticketSpendCapReachedSchema,
  voiceConverseSchema,
]) {
  ajv.addSchema(schema);
}
export const validateCommand = ajv.compile(commandSchema);
export const validateReport = ajv.getSchema(reportSchema.$id);
export const validateError = ajv.compile(errorSchema);
export const validateAgents = ajv.getSchema(agentsSchema.$id);
export const validateStatus = ajv.getSchema(statusSchema.$id);
export const validateTicket = ajv.getSchema(ticketSchema.$id);
export const validateTicketCancel = ajv.getSchema(ticketCancelSchema.$id);
export const validateTicketUsage = ajv.getSchema(ticketUsageSchema.$id);
export const validateTicketProgress = ajv.getSchema(ticketProgressSchema.$id);
export const validateTicketSpendCap = ajv.getSchema(ticketSpendCapSchema.$id);
export const validateTicketSpendCapReached = ajv.getSchema(ticketSpendCapReachedSchema.$id);
const validateVoiceConverseFrame = ajv.getSchema(voiceConverseSchema.$id);
export const validateVoiceConverse = (frames) => Array.isArray(frames) && frames.every(validateVoiceConverseFrame);

export const contractCases = [
  { name: 'agents', schema: agentsSchema, fixture: agents, validate: validateAgents },
  { name: 'status', schema: statusSchema, fixture: status, validate: validateStatus },
  { name: 'ticket', schema: ticketSchema, fixture: ticket, validate: validateTicket },
  { name: 'ticket cancel', schema: ticketCancelSchema, fixture: ticketCancel, validate: validateTicketCancel },
  { name: 'ticket usage', schema: ticketUsageSchema, fixture: ticketUsage, validate: validateTicketUsage },
  { name: 'ticket progress', schema: ticketProgressSchema, fixture: ticketProgress, validate: validateTicketProgress },
  { name: 'ticket spend cap', schema: ticketSpendCapSchema, fixture: ticketSpendCap, validate: validateTicketSpendCap },
  { name: 'ticket spend cap reached', schema: ticketSpendCapReachedSchema, fixture: ticketSpendCapReached, validate: validateTicketSpendCapReached },
];

for (const [validate, fixture] of [
  [validateCommand, command],
  [validateReport, report],
  [validateError, error],
  ...contractCases.map(({ validate, fixture }) => [validate, fixture]),
  [validateVoiceConverse, voiceConverse],
]) {
  if (!validate(fixture)) throw new Error(JSON.stringify(validate.errors));
}
