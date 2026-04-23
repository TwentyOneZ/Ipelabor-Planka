/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import isEmail from 'validator/lib/isEmail';
import React, { useCallback, useEffect, useMemo, useState } from 'react';
import classNames from 'classnames';
import { Link } from 'react-router';
import { useTranslation, Trans } from 'react-i18next';
import { Form, Grid, Header, Message } from 'semantic-ui-react';
import { useNestedRef } from '../../../hooks';
import { Input } from '../../../lib/custom-ui';

import api from '../../../api';
import Paths from '../../../constants/Paths';
import Config from '../../../constants/Config';

import styles from './Content.module.scss';

const createMessage = (error, isSubmitted) => {
  if (error) {
    switch (error.message) {
      case 'Password recovery is unavailable':
        return {
          type: 'error',
          content: 'common.passwordRecoveryUnavailable',
        };
      case 'Failed to fetch':
        return {
          type: 'warning',
          content: 'common.noInternetConnection',
        };
      case 'Network request failed':
        return {
          type: 'warning',
          content: 'common.serverConnectionFailed',
        };
      default:
        return {
          type: 'warning',
          content: 'common.unknownError',
        };
    }
  }

  if (isSubmitted) {
    return {
      type: 'success',
      content: 'common.passwordResetRequestSubmitted',
    };
  }

  return null;
};

const ForgotPassword = React.memo(() => {
  const [t] = useTranslation();

  const [email, setEmail] = useState('');
  const [error, setError] = useState(null);
  const [isSubmitted, setIsSubmitted] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const [emailFieldRef, handleEmailFieldRef] = useNestedRef('inputRef');

  const message = useMemo(() => createMessage(error, isSubmitted), [error, isSubmitted]);

  const handleEmailChange = useCallback((_, { value }) => {
    setEmail(value);
  }, []);

  const handleSubmit = useCallback(async () => {
    const cleanEmail = email.trim();

    if (!isEmail(cleanEmail)) {
      emailFieldRef.current.select();
      return;
    }

    setIsSubmitting(true);
    setError(null);

    try {
      await api.requestPasswordReset({
        email: cleanEmail,
      });

      setIsSubmitted(true);
    } catch (nextError) {
      setError(nextError);
    } finally {
      setIsSubmitting(false);
    }
  }, [email, emailFieldRef]);

  useEffect(() => {
    emailFieldRef.current.focus();
  }, [emailFieldRef]);

  return (
    <div className={classNames(styles.wrapper, styles.fullHeight)}>
      <Grid verticalAlign="middle" className={styles.grid}>
        <Grid.Column computer={6} tablet={16} mobile={16} className={styles.gridItem}>
          <div className={styles.login}>
            <div className={styles.form}>
              <div className={styles.logoWrapper}>
                <img src={`${Config.BASE_PATH}/assets/ipeboard.png`} alt="" className={styles.logo} />
              </div>
              <Header
                as="h2"
                textAlign="center"
                content={t('common.forgotPassword_title')}
                className={styles.formSubtitle}
              />
              <p className={styles.helperText}>{t('common.forgotPasswordDescription')}</p>
              {message && (
                <Message
                  {...{
                    [message.type]: true,
                  }}
                  visible
                  content={t(message.content)}
                />
              )}
              <Form size="large" onSubmit={handleSubmit}>
                <div className={styles.inputWrapper}>
                  <div className={styles.inputLabel}>{t('common.email')}</div>
                  <Input
                    fluid
                    ref={handleEmailFieldRef}
                    name="email"
                    value={email}
                    maxLength={256}
                    readOnly={isSubmitting}
                    className={styles.input}
                    onChange={handleEmailChange}
                  />
                </div>
                <Form.Button
                  fluid
                  primary
                  content={t('action.sendRecoveryLink')}
                  loading={isSubmitting}
                  disabled={isSubmitting}
                />
              </Form>
              <div className={styles.secondaryAction}>
                <Link to={Paths.LOGIN} className={styles.secondaryActionLink}>
                  {t('action.backToLogin')}
                </Link>
              </div>
            </div>
            <div className={styles.poweredBy}>
              <p className={styles.poweredByText}>
                <Trans i18nKey="common.poweredByPlanka">
                  {'Powered by '}
                  <a href="https://github.com/plankanban/planka" target="_blank" rel="noreferrer">
                    PLANKA
                  </a>
                </Trans>
              </p>
            </div>
          </div>
        </Grid.Column>
        <Grid.Column
          computer={10}
          only="computer"
          className={classNames(styles.gridItem, styles.cover)}
        >
          <div className={styles.coverOverlay} />
        </Grid.Column>
      </Grid>
    </div>
  );
});

export default ForgotPassword;
