import { util } from '@aws-appsync/utils';

/**
 * An owner's records whose sort key starts with a date from `from` through `to` (yyyy-MM-dd).
 * Sort keys start with the date, so "to" + "#￿" covers every record on the last day.
 */
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: 'ownerId = :owner AND sk BETWEEN :from AND :to',
      expressionValues: util.dynamodb.toMapValues({
        ':owner': ctx.args.ownerId,
        ':from': ctx.args.from,
        ':to': ctx.args.to + '#￿',
      }),
    },
    limit: 1000,
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result.items;
}
