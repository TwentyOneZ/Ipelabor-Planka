/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

const { AccessTokenSteps } = require('../../../constants');
const { isPassword } = require('../../../utils/validators');

const Errors = {
  INVALID_PASSWORD_RESET_TOKEN: {
    invalidPasswordResetToken: 'Invalid password reset token',
  },
};

module.exports = {
  inputs: {
    token: {
      type: 'string',
      maxLength: 1024,
      required: true,
    },
    password: {
      type: 'string',
      maxLength: 256,
      custom: isPassword,
      required: true,
    },
  },

  exits: {
    invalidPasswordResetToken: {
      responseType: 'forbidden',
    },
  },

  async fn(inputs) {
    let payload;

    try {
      payload = sails.helpers.utils.verifyJwtToken(inputs.token);
    } catch (error) {
      throw Errors.INVALID_PASSWORD_RESET_TOKEN;
    }

    if (payload.subject !== AccessTokenSteps.RESET_PASSWORD) {
      throw Errors.INVALID_PASSWORD_RESET_TOKEN;
    }

    const session = await Session.qm.getOneUndeletedByPendingToken(inputs.token);

    if (!session) {
      throw Errors.INVALID_PASSWORD_RESET_TOKEN;
    }

    let user = await User.qm.getOneById(session.userId, {
      withDeactivated: false,
    });

    if (
      !user ||
      user.isSsoUser ||
      user.email === sails.config.custom.defaultAdminEmail ||
      sails.config.custom.demoMode
    ) {
      throw Errors.INVALID_PASSWORD_RESET_TOKEN;
    }

    user = await sails.helpers.users.updateOne.with({
      values: {
        password: inputs.password,
      },
      record: user,
      actorUser: user,
      request: this.req,
    });

    await Session.qm.delete({
      userId: user.id,
      deletedAt: null,
      pendingToken: {
        '!=': null,
      },
    });

    return {
      item: null,
      included: {
        user: sails.helpers.users.presentOne(user),
      },
    };
  },
};
