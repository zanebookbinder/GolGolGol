import { util } from '@aws-appsync/utils';

/** Every record for one owner (used for Goals, which are few). */
export function request(ctx) {
  return {
    operation: 'Query',
    query: {
      expression: 'ownerId = :owner',
      expressionValues: util.dynamodb.toMapValues({ ':owner': ctx.args.ownerId }),
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
