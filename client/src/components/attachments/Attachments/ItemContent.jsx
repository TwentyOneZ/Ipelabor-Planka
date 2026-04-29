/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import React, { useCallback, useMemo } from 'react';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import { useDispatch, useSelector } from 'react-redux';
import { useTranslation } from 'react-i18next';
import { Button, Icon, Label, Loader } from 'semantic-ui-react';
import { push } from '../../../lib/redux-router';

import selectors from '../../../selectors';
import entryActions from '../../../entry-actions';
import { usePopupInClosableContext } from '../../../hooks';
import { isListArchiveOrTrash } from '../../../utils/record-helpers';
import { AttachmentTypes, BoardMembershipRoles } from '../../../constants/Enums';
import Paths from '../../../constants/Paths';
import EditStep from './EditStep';
import Favicon from '../../common/Favicon';
import TimeAgo from '../../common/TimeAgo';
import UserAvatar from '../../users/UserAvatar';

import styles from './ItemContent.module.scss';

const ItemContent = React.forwardRef(({ id, onOpen }, ref) => {
  const selectAttachmentById = useMemo(() => selectors.makeSelectAttachmentById(), []);
  const selectCardById = useMemo(() => selectors.makeSelectCardById(), []);
  const selectListById = useMemo(() => selectors.makeSelectListById(), []);
  const selectUserIdsByCardId = useMemo(() => selectors.makeSelectUserIdsByCardId(), []);

  const attachment = useSelector((state) => selectAttachmentById(state, id));
  const attachmentData = attachment.data || {};
  const linkedCardId = attachmentData.cardId;
  const linkedCard = useSelector((state) =>
    linkedCardId ? selectCardById(state, linkedCardId) : null,
  );
  const linkedList = useSelector((state) =>
    linkedCard ? selectListById(state, linkedCard.listId) : null,
  );
  const linkedUserIds =
    useSelector((state) => (linkedCardId ? selectUserIdsByCardId(state, linkedCardId) : [])) || [];
  const linkedCardPreview = linkedCard || (attachment.data ? attachmentData : null);
  const linkedCardUserIds = linkedCard ? linkedUserIds : [];
  const linkedCardUsers = linkedCard ? [] : attachmentData.users || [];

  const isCover = useSelector(
    (state) => id === selectors.selectCurrentCard(state).coverAttachmentId,
  );

  const canEdit = useSelector((state) => {
    const { listId } = selectors.selectCurrentCard(state);
    const list = selectListById(state, listId);

    if (isListArchiveOrTrash(list)) {
      return false;
    }

    const boardMembership = selectors.selectCurrentUserMembershipForCurrentBoard(state);
    return !!boardMembership && boardMembership.role === BoardMembershipRoles.EDITOR;
  });

  const dispatch = useDispatch();
  const [t] = useTranslation();

  const handleClick = useCallback(() => {
    if (attachment.type === AttachmentTypes.CARD) {
      if (linkedCardId) {
        dispatch(push(Paths.CARDS.replace(':id', linkedCardId)));
      }
    } else if (onOpen) {
      onOpen();
    } else {
      window.open(attachment.data.url, '_blank');
    }
  }, [onOpen, attachment, linkedCardId, dispatch]);

  const handleDownloadClick = useCallback(
    (event) => {
      event.stopPropagation();

      const linkElement = document.createElement('a');
      linkElement.href = attachment.data.url;
      linkElement.download = attachment.data.filename;
      linkElement.target = '_blank';
      linkElement.click();
    },
    [attachment.data],
  );

  const handleToggleCoverClick = useCallback(
    (event) => {
      event.stopPropagation();

      dispatch(
        entryActions.updateCurrentCard({
          coverAttachmentId: isCover ? null : id,
        }),
      );
    },
    [id, isCover, dispatch],
  );

  const EditPopup = usePopupInClosableContext(EditStep);

  if (!attachment.isPersisted) {
    return (
      <div className={classNames(styles.wrapper, styles.wrapperSubmitting)}>
        <Loader inverted />
      </div>
    );
  }

  return (
    /* eslint-disable-next-line jsx-a11y/click-events-have-key-events,
                                jsx-a11y/no-static-element-interactions */
    <div ref={ref} className={styles.wrapper} onClick={handleClick}>
      <div
        className={classNames(styles.thumbnail, {
          [styles.thumbnailCard]: attachment.type === AttachmentTypes.CARD,
        })}
        style={{
          background:
            attachment.type === AttachmentTypes.FILE &&
            attachment.data.image &&
            `url("${attachment.data.thumbnailUrls.outside360}") center / cover`,
        }}
      >
        {attachment.type === AttachmentTypes.FILE &&
          (attachment.data.image ? (
            isCover && (
              <Label
                corner="left"
                size="mini"
                icon={{
                  name: 'checkmark',
                  color: 'grey',
                  inverted: true,
                }}
                className={styles.thumbnailLabel}
              />
            )
          ) : (
            <span className={styles.thumbnailExtension}>{attachment.data.extension || '-'}</span>
          ))}
        {attachment.type === AttachmentTypes.LINK && <Favicon url={attachment.data.faviconUrl} />}
        {attachment.type === AttachmentTypes.CARD && <Icon fitted name="columns" />}
      </div>
      <div className={styles.details}>
        <span className={styles.name}>{attachment.name}</span>
        <span className={styles.information}>
          {attachment.type === AttachmentTypes.CARD && linkedCardPreview ? (
            <>
              {linkedCardPreview.isClosed ? t('common.closed') : t('common.active')}
              {linkedList
                ? ` - ${linkedList.name}`
                : linkedCardPreview.listName && ` - ${linkedCardPreview.listName}`}
            </>
          ) : (
            <TimeAgo date={attachment.createdAt} />
          )}
        </span>
        {attachment.type === AttachmentTypes.CARD && (
          <span className={styles.cardMeta}>
            {linkedCardPreview ? (
              <>
                {linkedCardUserIds.length > 0 && (
                  <span className={styles.cardUsers}>
                    {linkedCardUserIds.map((userId) => (
                      <span key={userId} className={styles.cardUser}>
                        <UserAvatar id={userId} size="tiny" />
                      </span>
                    ))}
                  </span>
                )}
                {linkedCardUsers.length > 0 && (
                  <span className={styles.cardUserNames}>
                    {linkedCardUsers.map((user) => user.name).join(', ')}
                  </span>
                )}
                <span className={styles.optionText}>{t('action.openCard')}</span>
              </>
            ) : (
              t('common.cardNotFound')
            )}
          </span>
        )}
        {attachment.type === AttachmentTypes.FILE && (
          <span className={styles.options}>
            <button type="button" className={styles.option} onClick={handleDownloadClick}>
              <Icon name="download" size="small" className={styles.optionIcon} />
              <span className={styles.optionText}>
                {t('action.download', {
                  context: 'title',
                })}
              </span>
            </button>
            {attachment.data.image && canEdit && (
              <button type="button" className={styles.option} onClick={handleToggleCoverClick}>
                <Icon
                  name="window maximize outline"
                  flipped="vertically"
                  size="small"
                  className={styles.optionIcon}
                />
                <span className={styles.optionText}>
                  {isCover
                    ? t('action.removeCover', {
                        context: 'title',
                      })
                    : t('action.makeCover', {
                        context: 'title',
                      })}
                </span>
              </button>
            )}
          </span>
        )}
      </div>
      {canEdit && (
        <EditPopup attachmentId={id}>
          <Button className={styles.editButton}>
            <Icon fitted name="pencil" size="small" />
          </Button>
        </EditPopup>
      )}
    </div>
  );
});

ItemContent.propTypes = {
  id: PropTypes.string.isRequired,
  onOpen: PropTypes.func,
};

ItemContent.defaultProps = {
  onOpen: undefined,
};

export default React.memo(ItemContent);
