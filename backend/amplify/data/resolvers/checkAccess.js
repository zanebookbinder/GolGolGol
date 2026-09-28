import { util, runtime } from '@aws-appsync/utils';

/**
 * First step of every read: allow the owner, or a viewer named by a Share (ownerId, viewerId = caller).
 */
export function request(ctx) {
  if (ctx.args.ownerId === ctx.identity.sub) {
    runtime.earlyReturn(true);
  }
  return {
    operation: 'GetItem',
    key: util.dynamodb.toMapValues({ ownerId: ctx.args.ownerId, viewerId: ctx.identity.sub }),
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  if (!ctx.result) {
    util.unauthorized();
  }
  return true;
}
