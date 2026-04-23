/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

const { AccessTokenSteps } = require('../../../constants');

const Errors = {
  ADMIN_LOGIN_REQUIRED_TO_INITIALIZE_INSTANCE: {
    adminLoginRequiredToInitializeInstance: 'Admin login required to initialize instance',
  },
};

const PENDING_TOKEN_EXPIRES_IN = 10 * 60;

module.exports = {
  inputs: {
    user: {
      type: 'ref',
      required: true,
    },
    request: {
      type: 'ref',
      required: true,
    },
    response: {
      type: 'ref',
      required: true,
    },
    remoteAddress: {
      type: 'string',
      required: true,
    },
    withHttpOnlyToken: {
      type: 'boolean',
    },
  },

  exits: {
    adminLoginRequiredToInitializeInstance: {},
    termsAcceptanceRequired: {},
  },

  async fn(inputs) {
    let user = inputs.user;
    const internalConfig = await InternalConfig.qm.getOneMain();

    if (!user.termsSignature) {
      const { signature } = await sails.hooks.terms.getPayload(user.language);

      ({ user } = await User.qm.updateOne(user.id, {
        termsSignature: signature,
        termsAcceptedAt: new Date().toISOString(),
      }));
    }

    if (!internalConfig.isInitialized) {
      if (user.role === User.Roles.ADMIN) {
        if (user.termsSignature) {
          await InternalConfig.qm.updateOneMain({
            isInitialized: true,
          });
        }
      } else {
        throw Errors.ADMIN_LOGIN_REQUIRED_TO_INITIALIZE_INSTANCE;
      }
    }

    if (!sails.hooks.terms.isSignatureValid(user.termsSignature)) {
      const { token: pendingToken, payload: pendingTokenPayload } =
        sails.helpers.utils.createJwtToken(
          AccessTokenSteps.ACCEPT_TERMS,
          undefined,
          PENDING_TOKEN_EXPIRES_IN,
        );

      const session = await sails.helpers.sessions.createOne.with({
        values: {
          pendingToken,
          userId: user.id,
          remoteAddress: inputs.remoteAddress,
          userAgent: inputs.request.headers['user-agent'],
        },
        withHttpOnlyToken: inputs.withHttpOnlyToken,
      });

      if (session.httpOnlyToken && !inputs.request.isSocket) {
        sails.helpers.utils.setHttpOnlyTokenCookie(
          session.httpOnlyToken,
          pendingTokenPayload,
          inputs.response,
        );
      }

      throw {
        termsAcceptanceRequired: {
          pendingToken,
          message: 'Terms acceptance required',
          step: AccessTokenSteps.ACCEPT_TERMS,
        },
      };
    }

    const { token: accessToken, payload: accessTokenPayload } = sails.helpers.utils.createJwtToken(
      inputs.user.id,
    );

    const session = await sails.helpers.sessions.createOne.with({
      values: {
        accessToken,
        userId: user.id,
        remoteAddress: inputs.remoteAddress,
        userAgent: inputs.request.headers['user-agent'],
      },
      withHttpOnlyToken: inputs.withHttpOnlyToken,
    });

    if (session.httpOnlyToken && !inputs.request.isSocket) {
      sails.helpers.utils.setHttpOnlyTokenCookie(
        session.httpOnlyToken,
        accessTokenPayload,
        inputs.response,
      );
    }

    return {
      item: accessToken,
    };
  },
};
