import { util } from '@aws-appsync/utils';

/**
 * Upserts a record the caller owns. The key is ownerId plus `sk` or `id` when the model has one.
 * Nobody but the owner can write: partners are strictly read-only.
 */
export function request(ctx) {
  const args = ctx.args;
  if (args.ownerId !== ctx.identity.sub) {
    util.unauthorized();
  }

  const key = { ownerId: args.ownerId };
  if (args.sk) {
    key.sk = args.sk;
  } else if (args.id) {
    key.id = args.id;
  }

  const now = util.time.nowISO8601();
  const item = { createdAt: now, updatedAt: now };
  for (const name of Object.keys(args)) {
    if (name !== 'ownerId' && name !== 'sk' && name !== 'id') {
      item[name] = args[name];
    }
  }

  return {
    operation: 'PutItem',
    key: util.dynamodb.toMapValues(key),
    attributeValues: util.dynamodb.toMapValues(item),
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result;
}
