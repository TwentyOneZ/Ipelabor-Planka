/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import React from 'react';
import { useSelector } from 'react-redux';
import { useLocation } from 'react-router';
import { Loader } from 'semantic-ui-react';

import selectors from '../../../selectors';
import Paths from '../../../constants/Paths';
import Content from './Content';
import ForgotPassword from './ForgotPassword';
import ResetPassword from './ResetPassword';

const Login = React.memo(() => {
  const isInitializing = useSelector(selectors.selectIsInitializing);
  const { pathname } = useLocation();

  if (isInitializing) {
    return <Loader active size="massive" />;
  }

  switch (pathname) {
    case Paths.FORGOT_PASSWORD:
      return <ForgotPassword />;
    case Paths.RESET_PASSWORD:
      return <ResetPassword />;
    default:
      return <Content />;
  }
});

export default Login;
