import { util, extensions } from '@aws-appsync/utils';

/**
 * Subscribing to an owner's DaySummaries requires being the owner or a viewer named by a Share.
 * Delivered events are filtered to that owner.
 */
export function request(ctx) {
  return {
    operation: 'GetItem',
    key: util.dynamodb.toMapValues({ ownerId: ctx.args.ownerId, viewerId: ctx.identity.sub }),
  };
}

export function response(ctx) {
  if (ctx.args.ownerId !== ctx.identity.sub && !ctx.result) {
    util.unauthorized();
  }
  extensions.setSubscriptionFilter(util.transform.toSubscriptionFilter({ ownerId: { eq: ctx.args.ownerId } }));
  return null;
}
