/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import orderBy from 'lodash/orderBy';
import React, { useEffect, useMemo, useState } from 'react';
import PropTypes from 'prop-types';
import { useDispatch, useSelector } from 'react-redux';
import { useTranslation } from 'react-i18next';
import { Button, Loader, Menu } from 'semantic-ui-react';
import { Input, Popup } from '../../lib/custom-ui';

import actions from '../../actions';
import api from '../../api';
import selectors from '../../selectors';
import { useField, useNestedRef } from '../../hooks';
import { getAccessToken } from '../../utils/access-token-storage';
import { isUserAdminOrProjectOwner } from '../../utils/record-helpers';
import CardMembershipsStepItem from './CardMembershipsStepItem';

import styles from '../board-memberships/PureBoardMembershipsStep/PureBoardMembershipsStep.module.scss';

const CardMembershipsStep = React.memo(
  ({
    currentUserIds,
    title,
    clearButtonContent,
    onUserSelect,
    onUserDeselect,
    onClear,
    onBack,
  }) => {
    const board = useSelector(selectors.selectCurrentBoard);
    const currentUser = useSelector(selectors.selectCurrentUser);
    const users = useSelector(selectors.selectActiveUsers);
    const boardId = board && board.id;
    const isPrivilegedUser = isUserAdminOrProjectOwner(currentUser);

    const dispatch = useDispatch();
    const [t] = useTranslation();
    const [search, handleSearchChange] = useField('');
    const [isLoading, setIsLoading] = useState(() => !isPrivilegedUser);
    const cleanSearch = useMemo(() => search.trim().toLowerCase(), [search]);

    const filteredUsers = useMemo(
      () =>
        orderBy(
          users.filter(
            (user) =>
              user.name.toLowerCase().includes(cleanSearch) ||
              (user.username && user.username.toLowerCase().includes(cleanSearch)),
          ),
          (user) => user.name.toLowerCase(),
        ),
      [users, cleanSearch],
    );

    const [searchFieldRef, handleSearchFieldRef] = useNestedRef('inputRef');

    useEffect(() => {
      searchFieldRef.current.focus({
        preventScroll: true,
      });
    }, [searchFieldRef]);

    useEffect(() => {
      let isCancelled = false;

      if (!boardId || isPrivilegedUser) {
        setIsLoading(false);
        return undefined;
      }

      const accessToken = getAccessToken();

      if (!accessToken) {
        setIsLoading(false);
        return undefined;
      }

      const fetchUsers = async () => {
        setIsLoading(true);

        try {
          const { items } = await api.getBoardUsers(boardId, {
            Authorization: `Bearer ${accessToken}`,
          });

          if (!isCancelled) {
            dispatch(actions.handleUsersReset(items));
          }
        } catch {
          /* empty */
        } finally {
          if (!isCancelled) {
            setIsLoading(false);
          }
        }
      };

      fetchUsers();

      return () => {
        isCancelled = true;
      };
    }, [boardId, dispatch, isPrivilegedUser]);

    return (
      <>
        <Popup.Header onBack={onBack}>
          {t(title, {
            context: 'title',
          })}
        </Popup.Header>
        <Popup.Content>
          <Input
            fluid
            ref={handleSearchFieldRef}
            value={search}
            placeholder={t('common.searchUsers')}
            maxLength={128}
            icon="search"
            onChange={handleSearchChange}
          />
          {filteredUsers.length > 0 && (
            <Menu secondary vertical className={styles.menu}>
              {filteredUsers.map((user) => (
                <CardMembershipsStepItem
                  key={user.id}
                  userId={user.id}
                  name={user.name}
                  isActive={currentUserIds.includes(user.id)}
                  onUserSelect={onUserSelect}
                  onUserDeselect={onUserDeselect}
                />
              ))}
            </Menu>
          )}
          {isLoading && filteredUsers.length === 0 && (
            <Loader active inline="centered" size="small" />
          )}
          {currentUserIds.length > 0 && onClear && (
            <Button
              fluid
              content={t(clearButtonContent)}
              className={styles.clearButton}
              onClick={onClear}
            />
          )}
        </Popup.Content>
      </>
    );
  },
);

CardMembershipsStep.propTypes = {
  currentUserIds: PropTypes.array.isRequired, // eslint-disable-line react/forbid-prop-types
  title: PropTypes.string,
  clearButtonContent: PropTypes.string,
  onUserSelect: PropTypes.func.isRequired,
  onUserDeselect: PropTypes.func,
  onClear: PropTypes.func,
  onBack: PropTypes.func,
};

CardMembershipsStep.defaultProps = {
  title: 'common.members',
  clearButtonContent: 'action.clear',
  onUserDeselect: undefined,
  onClear: undefined,
  onBack: undefined,
};

export default CardMembershipsStep;
