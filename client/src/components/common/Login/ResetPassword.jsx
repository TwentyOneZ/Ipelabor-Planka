/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import classNames from 'classnames';
import { Link, useSearchParams } from 'react-router';
import { useTranslation, Trans } from 'react-i18next';
import { Form, Grid, Header, Message } from 'semantic-ui-react';
import { useNestedRef } from '../../../hooks';
import { Input } from '../../../lib/custom-ui';

import api from '../../../api';
import Paths from '../../../constants/Paths';
import Config from '../../../constants/Config';
import { isPassword } from '../../../utils/validator';

import styles from './Content.module.scss';

const createMessage = (error, isSuccess) => {
  if (error) {
    switch (error.message) {
      case 'Passwords do not match':
        return {
          type: 'error',
          content: 'common.passwordsDoNotMatch',
        };
      case 'Invalid password reset token':
        return {
          type: 'error',
          content: 'common.invalidPasswordResetToken',
        };
      case 'Invalid password':
        return {
          type: 'error',
          content: 'common.invalidPassword',
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

  if (isSuccess) {
    return {
      type: 'success',
      content: 'common.passwordChangedSuccessfully',
    };
  }

  return null;
};

const ResetPassword = React.memo(() => {
  const [t] = useTranslation();
  const [searchParams] = useSearchParams();

  const token = searchParams.get('token') || '';

  const [password, setPassword] = useState('');
  const [passwordConfirmation, setPasswordConfirmation] = useState('');
  const [error, setError] = useState(
    token ? null : { message: 'Invalid password reset token' },
  );
  const [isSuccess, setIsSuccess] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const [passwordFieldRef, handlePasswordFieldRef] = useNestedRef('inputRef');
  const [confirmPasswordFieldRef, handleConfirmPasswordFieldRef] = useNestedRef('inputRef');

  const message = useMemo(() => createMessage(error, isSuccess), [error, isSuccess]);

  const handlePasswordChange = useCallback((_, { value }) => {
    setPassword(value);
  }, []);

  const handlePasswordConfirmationChange = useCallback((_, { value }) => {
    setPasswordConfirmation(value);
  }, []);

  const handleSubmit = useCallback(async () => {
    if (!token) {
      setError({ message: 'Invalid password reset token' });
      return;
    }

    if (!isPassword(password)) {
      setError({ message: 'Invalid password' });
      passwordFieldRef.current.select();
      return;
    }

    if (password !== passwordConfirmation) {
      setError({ message: 'Passwords do not match' });
      confirmPasswordFieldRef.current.select();
      return;
    }

    setIsSubmitting(true);
    setError(null);

    try {
      await api.resetPassword({
        token,
        password,
      });

      setIsSuccess(true);
    } catch (nextError) {
      setError(nextError);
    } finally {
      setIsSubmitting(false);
    }
  }, [confirmPasswordFieldRef, password, passwordConfirmation, passwordFieldRef, token]);

  useEffect(() => {
    if (token) {
      passwordFieldRef.current.focus();
    }
  }, [passwordFieldRef, token]);

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
                content={t('common.resetPassword_title')}
                className={styles.formSubtitle}
              />
              <p className={styles.helperText}>{t('common.resetPasswordDescription')}</p>
              {message && (
                <Message
                  {...{
                    [message.type]: true,
                  }}
                  visible
                  content={t(message.content)}
                />
              )}
              {!isSuccess && (
                <Form size="large" onSubmit={handleSubmit}>
                  <div className={styles.inputWrapper}>
                    <div className={styles.inputLabel}>{t('common.newPassword')}</div>
                    <Input.Password
                      fluid
                      ref={handlePasswordFieldRef}
                      name="password"
                      value={password}
                      maxLength={256}
                      readOnly={isSubmitting || !token}
                      className={styles.input}
                      onChange={handlePasswordChange}
                    />
                  </div>
                  <div className={styles.inputWrapper}>
                    <div className={styles.inputLabel}>{t('common.confirmPassword')}</div>
                    <Input.Password
                      fluid
                      ref={handleConfirmPasswordFieldRef}
                      name="passwordConfirmation"
                      value={passwordConfirmation}
                      maxLength={256}
                      readOnly={isSubmitting || !token}
                      className={styles.input}
                      onChange={handlePasswordConfirmationChange}
                    />
                  </div>
                  <Form.Button
                    fluid
                    primary
                    content={t('action.changePassword')}
                    loading={isSubmitting}
                    disabled={isSubmitting || !token}
                  />
                </Form>
              )}
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

export default ResetPassword;
