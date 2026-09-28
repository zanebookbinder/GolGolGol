import { defineFunction } from '@aws-amplify/backend';

export const acceptInvite = defineFunction({
  name: 'accept-invite',
  entry: './handler.ts',
  // Lives in the data stack: it's both a resolver and a reader of data tables, which would otherwise
  // create a circular dependency between stacks.
  resourceGroupName: 'data',
});
