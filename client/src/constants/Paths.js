/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import Config from './Config';

const ROOT = `${Config.BASE_PATH}/`;
const LOGIN = `${Config.BASE_PATH}/login`;
const FORGOT_PASSWORD = `${Config.BASE_PATH}/forgot-password`;
const RESET_PASSWORD = `${Config.BASE_PATH}/reset-password`;
const OIDC_CALLBACK = `${Config.BASE_PATH}/oidc-callback`;
const PROJECTS = `${Config.BASE_PATH}/projects/:id`;
const BOARDS = `${Config.BASE_PATH}/boards/:id`;
const CARDS = `${Config.BASE_PATH}/cards/:id`;

export default {
  ROOT,
  LOGIN,
  FORGOT_PASSWORD,
  RESET_PASSWORD,
  OIDC_CALLBACK,
  PROJECTS,
  BOARDS,
  CARDS,
};
