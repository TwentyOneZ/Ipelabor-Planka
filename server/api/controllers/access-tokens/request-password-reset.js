/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

const { URL } = require('url');

const { AccessTokenSteps } = require('../../../constants');
const { getRemoteAddress } = require('../../../utils/remote-address');

const PASSWORD_RESET_TOKEN_EXPIRES_IN = 60 * 60;

const Errors = {
  PASSWORD_RECOVERY_UNAVAILABLE: {
    passwordRecoveryUnavailable: 'Password recovery is unavailable',
  },
};

const getSmtpErrorHint = (error) => {
  if (!error) {
    return null;
  }

  const errorMessage = error.message || '';

  if (error.code === 'EDNS') {
    return 'Check the configured SMTP host.';
  }

  if (error.code === 'ETIMEDOUT') {
    return 'Check the configured SMTP host and port.';
  }

  if (error.code === 'EAUTH') {
    return 'Check the configured SMTP username and password.';
  }

  if (error.code === 'ESOCKET') {
    if (errorMessage.includes('ECONNREFUSED') || errorMessage.includes('ETIMEDOUT')) {
      return 'Check the configured SMTP host and port.';
    }

    if (errorMessage.includes('wrong version number')) {
      return 'Try toggling the SMTP secure connection setting.';
    }

    if (errorMessage.includes('certificate')) {
      return 'Try toggling the SMTP TLS certificate validation setting.';
    }
  }

  return null;
};

const logPasswordRecoveryError = (email, remoteAddress, error) => {
  const details = [
    `[password-recovery] Failed to send password reset email for "${email}" from IP ${remoteAddress}.`,
    `message="${error.message}"`,
    `code="${error.code || 'n/a'}"`,
    `command="${error.command || 'n/a'}"`,
    `responseCode="${error.responseCode || 'n/a'}"`,
  ];

  sails.log.error(details.join(' '));

  if (error.response) {
    sails.log.error(`[password-recovery] SMTP response: ${error.response.trim()}`);
  }

  const hint = getSmtpErrorHint(error);

  if (hint) {
    sails.log.error(`[password-recovery] Hint: ${hint}`);
  }

  if (error.stack) {
    sails.log.error(error.stack);
  }
};

const buildResetUrl = (token) => {
  const resetUrl = new URL(sails.config.custom.baseUrl);
  resetUrl.pathname = `${sails.config.custom.baseUrlPath}/reset-password`;
  resetUrl.searchParams.set('token', token);

  return resetUrl.toString();
};

const buildEmailHtml = (resetUrl) => `
  <p>Recebemos uma solicitacao para redefinir sua senha do Ipeboard.</p>
  <p>Para cadastrar uma nova senha, clique no link abaixo:</p>
  <p><a href="${resetUrl}">${resetUrl}</a></p>
  <p>Este link expira em 1 hora.</p>
  <p>Se voce nao solicitou esta alteracao, ignore este e-mail.</p>
`;

module.exports = {
  inputs: {
    email: {
      type: 'string',
      isEmail: true,
      maxLength: 256,
      required: true,
    },
  },

  exits: {
    passwordRecoveryUnavailable: {
      responseType: 'forbidden',
    },
  },

  async fn(inputs) {
    let transporter;

    try {
      ({ transporter } = await sails.helpers.utils.makeSmtpTransporter({
        connectionTimeout: 5000,
        greetingTimeout: 5000,
        socketTimeout: 10000,
        dnsTimeout: 3000,
      }));
    } catch (error) {
      sails.log.error(
        `[password-recovery] Failed to create SMTP transporter. message="${error.message}" code="${
          error.code || 'n/a'
        }"`,
      );

      if (error.stack) {
        sails.log.error(error.stack);
      }

      throw error;
    }

    if (!transporter) {
      sails.log.warn(
        '[password-recovery] Password recovery requested, but SMTP is not configured or unavailable.',
      );

      throw Errors.PASSWORD_RECOVERY_UNAVAILABLE;
    }

    const email = inputs.email.toLowerCase();
    const remoteAddress = getRemoteAddress(this.req);

    try {
      const user = await User.qm.getOneByEmail(email);

      if (
        !user ||
        user.isDeactivated ||
        user.isSsoUser ||
        user.email === sails.config.custom.defaultAdminEmail ||
        sails.config.custom.demoMode
      ) {
        return {
          item: null,
        };
      }

      const { token: pendingToken } = sails.helpers.utils.createJwtToken(
        AccessTokenSteps.RESET_PASSWORD,
        undefined,
        PASSWORD_RESET_TOKEN_EXPIRES_IN,
      );

      const resetUrl = buildResetUrl(pendingToken);

      try {
        await transporter.sendMail({
          to: user.email,
          subject: 'Recuperacao de senha do Ipeboard',
          text: `Use o link a seguir para redefinir sua senha: ${resetUrl}`,
          html: buildEmailHtml(resetUrl),
        });
      } catch (error) {
        logPasswordRecoveryError(email, remoteAddress, error);

        throw error;
      }

      await sails.helpers.sessions.createOne.with({
        values: {
          pendingToken,
          userId: user.id,
          remoteAddress,
          userAgent: this.req.headers['user-agent'],
        },
      });
    } finally {
      transporter.close();
    }

    return {
      item: null,
    };
  },
};
