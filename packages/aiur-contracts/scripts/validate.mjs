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
export const outboundEventEnvelopeSchema = read('schemas/outbound-event-envelope.v1.schema.json');
export const ticketLifecycleEventSchema = read('schemas/ticket-lifecycle-event.v1.schema.json');
export const ticketProgressEventSchema = read('schemas/ticket-progress-event.v1.schema.json');
export const ticketUsageEventSchema = read('schemas/ticket-usage-event.v1.schema.json');
export const ticketSpendCapSchema = read('schemas/ticket-spend-cap.v1.schema.json');
export const ticketSpendCapReachedSchema = read('schemas/ticket-spend-cap-reached.v1.schema.json');
export const ticketSpendCapReachedEventSchema = read('schemas/ticket-spend-cap-reached-event.v1.schema.json');
export const ticketCancelResultEventSchema = read('schemas/ticket-cancel-result-event.v1.schema.json');
export const report = read('fixtures/capabilities.v1.json');
export const error = read('fixtures/capability-error.v1.json');
export const agents = read('fixtures/agents.v1.json');
export const status = read('fixtures/status.v1.json');
export const ticket = read('fixtures/ticket.v1.json');
export const ticketCancel = read('fixtures/ticket-cancel.v1.json');
export const ticketUsage = read('fixtures/ticket-usage.v1.json');
export const ticketProgress = read('fixtures/ticket-progress.v1.json');
export const ticketLifecycleEvent = read('fixtures/ticket-lifecycle-event.v1.json');
export const ticketProgressEvent = read('fixtures/ticket-progress-event.v1.json');
export const ticketUsageEvent = read('fixtures/ticket-usage-event.v1.json');
export const ticketSpendCap = read('fixtures/ticket-spend-cap.v1.json');
export const ticketSpendCapReached = read('fixtures/ticket-spend-cap-reached.v1.json');
export const ticketSpendCapReachedEvent = read('fixtures/ticket-spend-cap-reached-event.v1.json');
export const ticketCancelResultEvent = read('fixtures/ticket-cancel-result-event.v1.json');
export const commandSchema = read('schemas/command.v2.schema.json');
export const command = read('fixtures/command.v2.json');
const ajv = new Ajv2020({ allErrors: true, formats: { 'date-time': true } });
for (const schema of [
  reportSchema,
  agentsSchema,
  statusSchema,
  ticketSchema,
  ticketCancelSchema,
  ticketUsageSchema,
  ticketProgressSchema,
  outboundEventEnvelopeSchema,
  ticketLifecycleEventSchema,
  ticketProgressEventSchema,
  ticketUsageEventSchema,
  ticketSpendCapSchema,
  ticketSpendCapReachedSchema,
  ticketSpendCapReachedEventSchema,
  ticketCancelResultEventSchema,
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
export const validateTicketLifecycleEvent = ajv.getSchema(ticketLifecycleEventSchema.$id);
export const validateTicketProgressEvent = ajv.getSchema(ticketProgressEventSchema.$id);
export const validateTicketUsageEvent = ajv.getSchema(ticketUsageEventSchema.$id);
export const validateTicketSpendCap = ajv.getSchema(ticketSpendCapSchema.$id);
export const validateTicketSpendCapReached = ajv.getSchema(ticketSpendCapReachedSchema.$id);
export const validateTicketSpendCapReachedEvent = ajv.getSchema(ticketSpendCapReachedEventSchema.$id);
export const validateTicketCancelResultEvent = ajv.getSchema(ticketCancelResultEventSchema.$id);

export const contractCases = [
  { name: 'agents', schema: agentsSchema, fixture: agents, validate: validateAgents },
  { name: 'status', schema: statusSchema, fixture: status, validate: validateStatus },
  { name: 'ticket', schema: ticketSchema, fixture: ticket, validate: validateTicket },
  { name: 'ticket cancel', schema: ticketCancelSchema, fixture: ticketCancel, validate: validateTicketCancel },
  { name: 'ticket usage', schema: ticketUsageSchema, fixture: ticketUsage, validate: validateTicketUsage },
  { name: 'ticket progress', schema: ticketProgressSchema, fixture: ticketProgress, validate: validateTicketProgress },
  { name: 'ticket lifecycle event', schema: ticketLifecycleEventSchema, fixture: ticketLifecycleEvent, validate: validateTicketLifecycleEvent, marker: 'v', version: 'v', additive: false },
  { name: 'ticket progress event', schema: ticketProgressEventSchema, fixture: ticketProgressEvent, validate: validateTicketProgressEvent, marker: 'v', version: 'v', additive: false },
  { name: 'ticket usage event', schema: ticketUsageEventSchema, fixture: ticketUsageEvent, validate: validateTicketUsageEvent, marker: 'v', version: 'v', additive: false },
  { name: 'ticket spend cap', schema: ticketSpendCapSchema, fixture: ticketSpendCap, validate: validateTicketSpendCap },
  { name: 'ticket spend cap reached', schema: ticketSpendCapReachedSchema, fixture: ticketSpendCapReached, validate: validateTicketSpendCapReached },
  { name: 'ticket spend cap reached event', schema: ticketSpendCapReachedEventSchema, fixture: ticketSpendCapReachedEvent, validate: validateTicketSpendCapReachedEvent, marker: 'v', version: 'v', additive: false },
  { name: 'ticket cancel result event', schema: ticketCancelResultEventSchema, fixture: ticketCancelResultEvent, validate: validateTicketCancelResultEvent, marker: 'v', version: 'v', additive: false },
];

for (const [validate, fixture] of [
  [validateCommand, command],
  [validateReport, report],
  [validateError, error],
  ...contractCases.map(({ validate, fixture }) => [validate, fixture]),
]) {
  if (!validate(fixture)) throw new Error(JSON.stringify(validate.errors));
}
